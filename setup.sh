#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  Odoo SaaS Platform - Initial Setup${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Check if running as root (recommended for setup)
if [[ $EUID -eq 0 ]]; then
   echo -e "${GREEN}✓ Running as root${NC}"
else
   echo -e "${YELLOW}⚠ Not running as root. Some operations may require sudo.${NC}"
fi

# Check Docker
echo -n "Checking Docker installation... "
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
    echo -e "${GREEN}✓ Docker $DOCKER_VERSION${NC}"
else
    echo -e "${RED}✗ Docker not installed${NC}"
    echo "Please install Docker first: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check Docker Compose
echo -n "Checking Docker Compose... "
if docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version | cut -d' ' -f4)
    echo -e "${GREEN}✓ Docker Compose $COMPOSE_VERSION${NC}"
elif command -v docker-compose &> /dev/null; then
    echo -e "${YELLOW}⚠ Using legacy docker-compose. Consider upgrading.${NC}"
    alias docker compose='docker-compose'
else
    echo -e "${RED}✗ Docker Compose not installed${NC}"
    exit 1
fi

# Create necessary directories
echo ""
echo "Creating directory structure..."
directories=(
    "admin"
    "app"
    "config/nginx/snippets"
    "config/odoo"
    "custom-addons"
    "letsencrypt"
    "certbot-www"
)

for dir in "${directories[@]}"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        echo -e "${GREEN}✓${NC} Created $dir"
    else
        echo -e "${BLUE}○${NC} $dir already exists"
    fi
done

# Check for required files
echo ""
echo "Checking required files..."

# Check if .env exists
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        echo -e "${YELLOW}Creating .env from template...${NC}"
        cp .env.example .env
        echo -e "${GREEN}✓${NC} Created .env file"
        echo -e "${RED}IMPORTANT: Edit .env file with your configuration!${NC}"
    else
        echo -e "${RED}✗ No .env.example found!${NC}"
        echo "Creating minimal .env file..."
        cat > .env << 'EOF'
# Minimal configuration - EDIT THESE VALUES!
PG_USER=odoo
PG_PASSWORD=changeme_password_$(openssl rand -hex 8)
DOMAIN=odoo.example.com
ADMIN_DOMAIN=admin.odoo.example.com
SECRET_KEY=$(openssl rand -hex 32)
BOOTSTRAP_EMAIL=owner@example.com
BOOTSTRAP_PASSWORD=changeme_admin_$(openssl rand -hex 8)
REDIS_URL=redis://redis:6379/0
EOF
        echo -e "${GREEN}✓${NC} Created minimal .env file"
    fi
fi

# Check admin_dashboard.py
if [[ ! -f app/admin_dashboard.py ]]; then
    echo -e "${RED}✗ app/admin_dashboard.py not found!${NC}"
    echo "Please ensure admin_dashboard.py is in the app/ directory"
    exit 1
else
    echo -e "${GREEN}✓${NC} app/admin_dashboard.py exists"
fi

# Check Dockerfile
if [[ ! -f admin/Dockerfile ]]; then
    echo -e "${YELLOW}Creating admin/Dockerfile...${NC}"
    cat > admin/Dockerfile << 'EOF'
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_ENV=1 \
    ADMIN_DB_PATH=/opt/odoo-admin/admin.db

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates gcc pkg-config libpq-dev postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/odoo-admin && chmod 755 /opt/odoo-admin

COPY admin_dashboard.py /app/admin_dashboard.py

RUN pip install --no-cache-dir \
    flask itsdangerous python-dotenv flask_sqlalchemy flask_login bcrypt redis rq requests \
    boto3 stripe pycryptodome cryptography psycopg2-binary

EXPOSE 9090

CMD ["python", "/app/admin_dashboard.py"]
EOF
    echo -e "${GREEN}✓${NC} Created admin/Dockerfile"
fi

# Check Odoo config
if [[ ! -f config/odoo/odoo.conf ]]; then
    echo -e "${YELLOW}Creating config/odoo/odoo.conf...${NC}"
    cat > config/odoo/odoo.conf << 'EOF'
[options]
admin_passwd = changeme_master
db_host = postgres
db_port = 5432
db_user = odoo
db_password = changeme
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
logfile = /var/lib/odoo/odoo.log
dbfilter = ^%d$
proxy_mode = True
limit_time_cpu = 120
limit_time_real = 240
EOF
    echo -e "${GREEN}✓${NC} Created config/odoo/odoo.conf"
    echo -e "${RED}IMPORTANT: Update db_password and admin_passwd in config/odoo/odoo.conf${NC}"
fi

# Check Nginx config
if [[ ! -f config/nginx/site.conf ]]; then
    echo -e "${RED}✗ config/nginx/site.conf not found!${NC}"
    echo "Please ensure Nginx configuration files are in place"
fi

# Create admin basic auth
if [[ ! -f config/nginx/.admin_htpasswd ]]; then
    echo ""
    echo -e "${YELLOW}Creating HTTP Basic Auth for Admin Dashboard...${NC}"
    echo "Enter password for 'admin' user:"
    
    docker run --rm -it \
        -v "$(pwd)/config/nginx:/etc/nginx" \
        nginx:alpine sh -c \
        'apk add --no-cache apache2-utils && htpasswd -c /etc/nginx/.admin_htpasswd admin' || {
        echo -e "${RED}Failed to create htpasswd file${NC}"
        echo "You can create it manually later with:"
        echo "  htpasswd -c config/nginx/.admin_htpasswd admin"
    }
fi

# Generate secure passwords in .env if still default
echo ""
echo "Checking .env configuration..."
if grep -q "changeme" .env 2>/dev/null || grep -q "CHANGEME" .env 2>/dev/null; then
    echo -e "${YELLOW}⚠ Found default values in .env${NC}"
    read -p "Would you like to generate secure passwords? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Backup current .env
        cp .env .env.backup
        
        # Generate secure passwords
        PG_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-20)
        SECRET_KEY=$(openssl rand -hex 32)
        BOOTSTRAP_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        WEBHOOK_SECRET=$(openssl rand -hex 16)
        
        # Update .env with secure values
        sed -i.tmp "s/PG_PASSWORD=.*/PG_PASSWORD=$PG_PASS/" .env
        sed -i.tmp "s/SECRET_KEY=.*/SECRET_KEY=$SECRET_KEY/" .env
        sed -i.tmp "s/BOOTSTRAP_PASSWORD=.*/BOOTSTRAP_PASSWORD=$BOOTSTRAP_PASS/" .env
        sed -i.tmp "s/WEBHOOK_SECRET=.*/WEBHOOK_SECRET=$WEBHOOK_SECRET/" .env
        
        echo -e "${GREEN}✓${NC} Generated secure passwords"
        echo -e "${YELLOW}Saved backup to .env.backup${NC}"
        echo ""
        echo "Generated credentials:"
        echo "  PostgreSQL Password: $PG_PASS"
        echo "  Bootstrap Password: $BOOTSTRAP_PASS"
        echo -e "${RED}SAVE THESE CREDENTIALS SECURELY!${NC}"
    fi
fi

# Summary
echo ""
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  Setup Summary${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Check what needs to be done
TODO_COUNT=0
echo "Required actions:"

if grep -q "example.com" .env 2>/dev/null; then
    echo -e "${RED}[ ]${NC} Update domain names in .env"
    ((TODO_COUNT++))
fi

if grep -q "changeme\|CHANGEME" .env 2>/dev/null; then
    echo -e "${RED}[ ]${NC} Update passwords in .env"
    ((TODO_COUNT++))
fi

if [[ -f config/odoo/odoo.conf ]] && grep -q "changeme" config/odoo/odoo.conf; then
    echo -e "${RED}[ ]${NC} Update passwords in config/odoo/odoo.conf"
    ((TODO_COUNT++))
fi

if [[ $TODO_COUNT -eq 0 ]]; then
    echo -e "${GREEN}✓ Configuration looks good!${NC}"
else
    echo ""
    echo -e "${YELLOW}Please complete the above actions before starting.${NC}"
fi

echo ""
echo "Next steps:"
echo "1. Edit .env file with your configuration"
echo "2. Update config/odoo/odoo.conf with matching passwords"
echo "3. Start services: docker compose up -d --build"
echo "4. Check logs: docker compose logs -f"
echo "5. Access Admin Dashboard at http://localhost:9090"
echo ""
echo -e "${GREEN}Setup preparation complete!${NC}"