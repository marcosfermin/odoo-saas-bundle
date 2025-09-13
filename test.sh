#!/usr/bin/env bash
set -euo pipefail

# Test script for Odoo SaaS Platform
# This script performs various checks to ensure the platform is working correctly

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
BASE_URL="${BASE_URL:-http://localhost}"
ADMIN_URL="${ADMIN_URL:-http://localhost:9090}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

echo -e "${GREEN}Odoo SaaS Platform Test Suite${NC}"
echo "=============================="
echo ""

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Function to test endpoint
test_endpoint() {
    local name=$1
    local url=$2
    local expected_code=${3:-200}
    local auth=${4:-}
    
    echo -n "Testing $name... "
    
    if [[ -n "$auth" ]]; then
        response=$(curl -s -o /dev/null -w "%{http_code}" -u "$auth" "$url")
    else
        response=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    fi
    
    if [[ "$response" == "$expected_code" ]]; then
        echo -e "${GREEN}✓${NC} (HTTP $response)"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} (HTTP $response, expected $expected_code)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Function to test Docker container
test_docker_container() {
    local name=$1
    echo -n "Testing Docker container $name... "
    
    if docker ps --format '{{.Names}}' | grep -q "$name"; then
        if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == "true" ]]; then
            echo -e "${GREEN}✓${NC} (running)"
            ((TESTS_PASSED++))
            return 0
        fi
    fi
    
    echo -e "${RED}✗${NC} (not running)"
    ((TESTS_FAILED++))
    return 1
}

# Function to test Kubernetes pod
test_k8s_pod() {
    local label=$1
    local namespace=${2:-odoo-saas}
    echo -n "Testing K8s pods with label $label... "
    
    ready_pods=$(kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    total_pods=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l)
    
    if [[ "$ready_pods" -gt 0 ]] && [[ "$ready_pods" == "$total_pods" ]]; then
        echo -e "${GREEN}✓${NC} ($ready_pods/$total_pods ready)"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} ($ready_pods/$total_pods ready)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Function to test database connection
test_database() {
    echo -n "Testing PostgreSQL connection... "
    
    if PGPASSWORD="${PG_PASSWORD:-odoo}" psql -h "${PG_HOST:-localhost}" -U "${PG_USER:-odoo}" -d postgres -c "SELECT 1" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Function to test Redis
test_redis() {
    echo -n "Testing Redis connection... "
    
    if redis-cli -h "${REDIS_HOST:-localhost}" ping 2>/dev/null | grep -q "PONG"; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Detect deployment type
echo "Detecting deployment type..."
if docker ps &>/dev/null && docker ps | grep -q "odoo"; then
    DEPLOYMENT="docker"
    echo "Detected: Docker deployment"
elif kubectl get pods -n odoo-saas &>/dev/null; then
    DEPLOYMENT="kubernetes"
    echo "Detected: Kubernetes deployment"
elif systemctl is-active odoo &>/dev/null; then
    DEPLOYMENT="host"
    echo "Detected: Host installation"
else
    echo -e "${YELLOW}Warning: Could not detect deployment type${NC}"
    DEPLOYMENT="unknown"
fi

echo ""
echo "Running tests..."
echo "----------------"

# Common tests
test_endpoint "Odoo main page" "$BASE_URL/web/login"
test_endpoint "Admin login page" "$ADMIN_URL/login"
test_endpoint "Admin auth check" "$ADMIN_URL/" 302
test_endpoint "Health check" "$ADMIN_URL/health"

# Deployment-specific tests
if [[ "$DEPLOYMENT" == "docker" ]]; then
    echo ""
    echo "Docker-specific tests:"
    test_docker_container "odoo_pg"
    test_docker_container "odoo_redis"
    test_docker_container "odoo_app"
    test_docker_container "odoo_admin"
    test_docker_container "odoo_nginx"
    
    # Test Docker networking
    echo -n "Testing Docker network... "
    if docker network ls | grep -q "odoo"; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
    fi
    
elif [[ "$DEPLOYMENT" == "kubernetes" ]]; then
    echo ""
    echo "Kubernetes-specific tests:"
    test_k8s_pod "app=redis"
    test_k8s_pod "app=odoo"
    test_k8s_pod "app=admin"
    test_k8s_pod "app=admin-workers"
    
    # Test Ingress
    echo -n "Testing Ingress... "
    if kubectl get ingress -n odoo-saas --no-headers 2>/dev/null | grep -q "odoo"; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
    fi
    
    # Test Certificates
    echo -n "Testing TLS certificates... "
    cert_ready=$(kubectl get certificate -n odoo-saas -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    if [[ "$cert_ready" -gt 0 ]]; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${YELLOW}⚠${NC} (not ready yet)"
    fi
    
elif [[ "$DEPLOYMENT" == "host" ]]; then
    echo ""
    echo "Host-specific tests:"
    
    # Test systemd services
    for service in odoo odoo-admin odoo-admin-worker@1; do
        echo -n "Testing service $service... "
        if systemctl is-active "$service" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}✗${NC}"
            ((TESTS_FAILED++))
        fi
    done
    
    # Test Nginx
    echo -n "Testing Nginx configuration... "
    if nginx -t &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
    fi
fi

# Database and Redis tests (if accessible)
echo ""
echo "Backend service tests:"
test_database
test_redis

# Test tenant creation (optional)
echo ""
read -p "Test tenant creation? (requires admin credentials) (y/n): " test_tenant
if [[ "$test_tenant" == "y" ]]; then
    echo -n "Creating test tenant... "
    
    # Get CSRF token
    csrf_token=$(curl -s -c /tmp/cookies.txt "$ADMIN_URL/login" | grep -oP 'name="_csrf"\s+value="\K[^"]+' || echo "")
    
    # Login
    login_response=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies.txt -c /tmp/cookies.txt \
        -X POST "$ADMIN_URL/login" \
        -d "email=$ADMIN_USER&password=$ADMIN_PASS&_csrf=$csrf_token")
    
    if [[ "$login_response" == "302" ]] || [[ "$login_response" == "200" ]]; then
        # Create tenant
        tenant_name="test_$(date +%s)"
        create_response=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies.txt \
            -X POST "$ADMIN_URL/tenants/create" \
            -d "dbname=$tenant_name&_csrf=$csrf_token")
        
        if [[ "$create_response" == "302" ]] || [[ "$create_response" == "200" ]]; then
            echo -e "${GREEN}✓${NC} (tenant: $tenant_name)"
            ((TESTS_PASSED++))
            
            # Test tenant access
            sleep 5
            test_endpoint "Tenant access" "http://$tenant_name.$BASE_URL/web/login" 200
        else
            echo -e "${RED}✗${NC} (HTTP $create_response)"
            ((TESTS_FAILED++))
        fi
    else
        echo -e "${RED}✗${NC} (login failed)"
        ((TESTS_FAILED++))
    fi
    
    rm -f /tmp/cookies.txt
fi

# Performance test (optional)
echo ""
read -p "Run basic performance test? (y/n): " perf_test
if [[ "$perf_test" == "y" ]]; then
    echo "Running performance test (10 requests)..."
    
    total_time=0
    for i in {1..10}; do
        response_time=$(curl -s -o /dev/null -w "%{time_total}" "$BASE_URL/web/login")
        total_time=$(echo "$total_time + $response_time" | bc)
        echo -n "."
    done
    echo ""
    
    avg_time=$(echo "scale=3; $total_time / 10" | bc)
    echo "Average response time: ${avg_time}s"
    
    if (( $(echo "$avg_time < 1.0" | bc -l) )); then
        echo -e "${GREEN}Performance: Good${NC}"
    elif (( $(echo "$avg_time < 2.0" | bc -l) )); then
        echo -e "${YELLOW}Performance: Acceptable${NC}"
    else
        echo -e "${RED}Performance: Poor${NC}"
    fi
fi

# Summary
echo ""
echo "=============================="
echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed! Platform is working correctly.${NC}"
    exit 0
else
    echo -e "${YELLOW}Some tests failed. Please check the configuration.${NC}"
    exit 1
fi