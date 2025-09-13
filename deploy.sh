#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DEPLOYMENT_TYPE="${1:-docker}"
NAMESPACE="odoo-saas"

echo -e "${GREEN}Odoo SaaS Platform Deployment Script${NC}"
echo "======================================"
echo ""

# Function to check command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

# Function to wait for pod readiness
wait_for_pod() {
    local label=$1
    local timeout=${2:-300}
    echo -e "${YELLOW}Waiting for pods with label $label to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l "$label" -n "$NAMESPACE" --timeout="${timeout}s"
}

# Docker Deployment
if [[ "$DEPLOYMENT_TYPE" == "docker" ]]; then
    echo -e "${GREEN}Starting Docker deployment...${NC}"
    
    check_command docker
    check_command docker-compose
    
    # Check for environment file
    if [[ ! -f .env ]]; then
        echo -e "${YELLOW}Creating .env file from template...${NC}"
        cp .env.example .env
        echo -e "${RED}Please edit .env file with your configuration${NC}"
        exit 1
    fi
    
    # Create necessary directories
    mkdir -p admin config/odoo config/nginx/snippets custom-addons letsencrypt certbot-www
    
    # Copy admin dashboard if it exists
    if [[ -f app/admin_dashboard.py ]]; then
        cp app/admin_dashboard.py admin/
    fi
    
    # Check for basic auth file
    if [[ ! -f config/nginx/.admin_htpasswd ]]; then
        echo -e "${YELLOW}Creating admin basic auth...${NC}"
        docker run --rm -it -v "$(pwd)/config/nginx:/etc/nginx" \
            nginx:alpine sh -c 'apk add --no-cache apache2-utils && \
            htpasswd -c /etc/nginx/.admin_htpasswd admin'
    fi
    
    # Build and start services
    echo -e "${GREEN}Building and starting services...${NC}"
    docker-compose build
    docker-compose up -d
    
    # Wait for services to be healthy
    echo -e "${YELLOW}Waiting for services to be healthy...${NC}"
    sleep 10
    
    # Check service status
    docker-compose ps
    
    echo -e "${GREEN}Docker deployment complete!${NC}"
    echo ""
    echo "Access points:"
    echo "- Odoo: http://localhost (configure domain in /etc/hosts)"
    echo "- Admin: http://localhost:9090"
    echo ""
    echo "Next steps:"
    echo "1. Configure DNS to point to this server"
    echo "2. Run TLS certificate script:"
    echo "   ./scripts/letsencrypt_webroot.sh"
    echo "3. Create first tenant in Admin Dashboard"

# Kubernetes Deployment
elif [[ "$DEPLOYMENT_TYPE" == "kubernetes" ]] || [[ "$DEPLOYMENT_TYPE" == "k8s" ]]; then
    echo -e "${GREEN}Starting Kubernetes deployment...${NC}"
    
    check_command kubectl
    
    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        exit 1
    fi
    
    # Check for required CRDs
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    if ! kubectl get crd certificates.cert-manager.io &> /dev/null; then
        echo -e "${RED}Error: cert-manager is not installed${NC}"
        echo "Install with: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml"
        exit 1
    fi
    
    if ! kubectl get deploy -n ingress-nginx &> /dev/null; then
        echo -e "${YELLOW}Warning: NGINX Ingress Controller may not be installed${NC}"
        echo "Install with: helm install ingress-nginx ingress-nginx/ingress-nginx"
    fi
    
    # Apply manifests in order
    echo -e "${GREEN}Applying Kubernetes manifests...${NC}"
    
    # 1. Namespace
    echo "Creating namespace..."
    kubectl apply -f k8s/00-namespace.yaml
    
    # 2. ClusterIssuer for Let's Encrypt
    echo "Creating ClusterIssuer..."
    kubectl apply -f k8s/01-clusterissuer-letsencrypt.yaml
    
    # 3. ConfigMaps
    echo "Creating ConfigMaps..."
    kubectl apply -f k8s/02-configmaps/ -R
    
    # 4. Secrets
    echo "Creating Secrets..."
    if [[ ! -f k8s/03-secrets/configured ]]; then
        echo -e "${RED}Warning: Secrets not configured!${NC}"
        echo "Please edit k8s/03-secrets/app-secrets.yaml with your configuration"
        echo "Also create basic-auth secret:"
        echo "  htpasswd -nb admin yourpassword | base64 -w0"
        echo "Then add to k8s/03-secrets/basic-auth-secret.yaml"
        exit 1
    fi
    kubectl apply -f k8s/03-secrets/ -R
    
    # 5. Redis
    echo "Deploying Redis..."
    kubectl apply -f k8s/10-redis/ -R
    wait_for_pod "app=redis"
    
    # 6. PostgreSQL (optional)
    read -p "Deploy PostgreSQL in cluster? (y/n, default: n): " deploy_pg
    if [[ "$deploy_pg" == "y" ]]; then
        echo "Deploying PostgreSQL..."
        kubectl apply -f k8s/50-postgres/ -R
        wait_for_pod "app=postgres"
    fi
    
    # 7. Storage class selection
    echo -e "${YELLOW}Select storage provider:${NC}"
    echo "1) AWS EFS"
    echo "2) Azure Files"
    echo "3) GKE Filestore"
    echo "4) OCI File Storage"
    echo "5) Skip (manual configuration)"
    read -p "Choice (1-5): " storage_choice
    
    case $storage_choice in
        1) kubectl apply -f k8s/storage/aws-efs.yaml ;;
        2) kubectl apply -f k8s/storage/azure-files.yaml ;;
        3) kubectl apply -f k8s/storage/gke-filestore.yaml ;;
        4) kubectl apply -f k8s/storage/oci-fss.yaml ;;
        *) echo "Skipping storage configuration" ;;
    esac
    
    # 8. Odoo
    echo "Deploying Odoo..."
    kubectl apply -f k8s/20-odoo/ -R
    wait_for_pod "app=odoo"
    
    # 9. Admin Dashboard
    echo "Deploying Admin Dashboard..."
    kubectl apply -f k8s/30-admin/ -R
    wait_for_pod "app=admin"
    
    # 10. HPA
    echo "Creating HorizontalPodAutoscaler..."
    kubectl apply -f k8s/40-odoo-hpa.yaml
    
    # 11. KEDA (optional)
    if kubectl get crd scaledobjects.keda.sh &> /dev/null; then
        echo "Deploying KEDA ScaledObjects..."
        kubectl apply -f k8s/30-admin/admin-workers-keda.yaml
    fi
    
    # 12. Ingress
    echo "Creating Ingress..."
    kubectl apply -f k8s/90-ingress.yaml
    
    # Show status
    echo ""
    echo -e "${GREEN}Kubernetes deployment complete!${NC}"
    echo ""
    kubectl get pods -n "$NAMESPACE"
    echo ""
    kubectl get ingress -n "$NAMESPACE"
    echo ""
    echo "Next steps:"
    echo "1. Configure DNS to point to your Ingress IP"
    echo "2. Wait for certificates to be issued (check with: kubectl get certificate -n $NAMESPACE)"
    echo "3. Access Admin Dashboard at https://admin.odoo.example.com"

# Host Installation
elif [[ "$DEPLOYMENT_TYPE" == "host" ]]; then
    echo -e "${GREEN}Starting host installation...${NC}"
    
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root for host installation${NC}"
        exit 1
    fi
    
    # Run installation scripts
    echo "Installing Odoo..."
    bash scripts/install_saas.sh
    
    echo "Installing Admin Dashboard..."
    bash scripts/install_admin.sh
    
    # Configure Nginx
    echo "Configuring Nginx..."
    cp config/nginx/site.conf /etc/nginx/sites-available/odoo.conf
    
    # Fix upstreams for host installation
    sed -i 's/server odoo:8069/server 127.0.0.1:8069/g' /etc/nginx/sites-available/odoo.conf
    sed -i 's/server odoo:8072/server 127.0.0.1:8072/g' /etc/nginx/sites-available/odoo.conf
    sed -i 's/server admin:9090/server 127.0.0.1:9090/g' /etc/nginx/sites-available/odoo.conf
    
    ln -sf /etc/nginx/sites-available/odoo.conf /etc/nginx/sites-enabled/
    
    # Test and reload Nginx
    nginx -t && systemctl reload nginx
    
    # Start services
    echo "Starting services..."
    systemctl start odoo odoo-admin
    systemctl start odoo-admin-worker@{1..3}
    
    echo -e "${GREEN}Host installation complete!${NC}"
    echo ""
    echo "Services status:"
    systemctl status odoo --no-pager | head -n 5
    systemctl status odoo-admin --no-pager | head -n 5
    echo ""
    echo "Next steps:"
    echo "1. Edit /opt/odoo-admin/.env with your configuration"
    echo "2. Update /etc/odoo.conf with master password"
    echo "3. Restart services: systemctl restart odoo odoo-admin"
    echo "4. Configure DNS and run Let's Encrypt script"

else
    echo -e "${RED}Invalid deployment type: $DEPLOYMENT_TYPE${NC}"
    echo "Usage: $0 [docker|kubernetes|k8s|host]"
    exit 1
fi

echo ""
echo -e "${GREEN}Deployment script finished!${NC}"