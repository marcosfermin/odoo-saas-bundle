#!/usr/bin/env bash
set -euo pipefail

# === Odoo SaaS base install (multi-tenant ready) ===
ODOO_VERSION="${ODOO_VERSION:-16.0}"
ODOO_USER="${ODOO_USER:-odoo}"
ODOO_HOME="/opt/${ODOO_USER}"
ODOO_DIR="${ODOO_HOME}/odoo-${ODOO_VERSION}"
ODOO_VENV="${ODOO_HOME}/venv"
LOG_DIR="${ODOO_HOME}/logs"
CONFIG="/etc/odoo.conf"

if [[ $EUID -ne 0 ]]; then 
    echo "This script must be run as root"
    exit 1
fi

echo "Installing Odoo SaaS Platform..."
echo "Version: ${ODOO_VERSION}"
echo "User: ${ODOO_USER}"
echo "Home: ${ODOO_HOME}"

# Update system and install dependencies
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git python3 python3-venv python3-pip python3-dev \
    postgresql postgresql-client nginx libpq-dev build-essential \
    wkhtmltopdf libev-dev libc-ares-dev libldap2-dev libsasl2-dev \
    libssl-dev libxml2-dev libxslt1-dev libjpeg-dev libfreetype6-dev \
    zlib1g-dev curl

# Create system user and folders
if ! id -u "${ODOO_USER}" &>/dev/null; then
    adduser --system --quiet --home "${ODOO_HOME}" --group "${ODOO_USER}"
    echo "Created user: ${ODOO_USER}"
fi

mkdir -p "${LOG_DIR}" "${ODOO_HOME}/custom-addons"
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

# Configure PostgreSQL
systemctl enable --now postgresql

# Create database user with createdb privilege
sudo -u postgres psql -c "SELECT 1 FROM pg_user WHERE usename = '${ODOO_USER}'" | grep -q 1 || \
    sudo -u postgres createuser -d "${ODOO_USER}"
echo "PostgreSQL user configured"

# Fetch Odoo sources
if [[ ! -d "${ODOO_DIR}" ]]; then
    echo "Cloning Odoo ${ODOO_VERSION}..."
    sudo -u "${ODOO_USER}" git clone --depth=1 --branch "${ODOO_VERSION}" \
        https://github.com/odoo/odoo.git "${ODOO_DIR}"
fi

# Create Python virtual environment
echo "Setting up Python virtual environment..."
sudo -u "${ODOO_USER}" python3 -m venv "${ODOO_VENV}"

# Detect Python version for gevent compatibility
PYTHON_VERSION=$(sudo -u "${ODOO_USER}" "${ODOO_VENV}/bin/python" -c \
    'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Python version: ${PYTHON_VERSION}"

# Upgrade pip and install build tools
sudo -u "${ODOO_USER}" bash -c "${ODOO_VENV}/bin/pip install --upgrade pip wheel setuptools"

# Handle gevent compatibility for Python 3.10+
if [[ "$PYTHON_VERSION" == "3.10" ]] || [[ "$PYTHON_VERSION" == "3.11" ]]; then
    echo "Applying Python ${PYTHON_VERSION} compatibility fixes..."
    # Remove problematic gevent pin from requirements
    sudo -u "${ODOO_USER}" sed -i '/^gevent==/d' "${ODOO_DIR}/requirements.txt"
    # Install compatible versions
    sudo -u "${ODOO_USER}" bash -c "${ODOO_VENV}/bin/pip install 'greenlet>=2.0.2' 'gevent>=22.10.2'"
fi

# Install Odoo requirements
echo "Installing Odoo requirements..."
sudo -u "${ODOO_USER}" bash -c "cd '${ODOO_DIR}' && ${ODOO_VENV}/bin/pip install -r requirements.txt"

# Create Odoo configuration
cat > "${CONFIG}" <<EOF
[options]
admin_passwd = changeme_master_password
db_host = False
db_port = False
db_user = ${ODOO_USER}
db_password = False
addons_path = ${ODOO_DIR}/addons,${ODOO_HOME}/custom-addons
logfile = ${LOG_DIR}/odoo.log
log_level = info
longpolling_port = 8072
workers = 0
proxy_mode = True
dbfilter = ^%d\$
limit_time_cpu = 120
limit_time_real = 240
limit_request = 8192
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
max_cron_threads = 2
EOF

chown "${ODOO_USER}:${ODOO_USER}" "${CONFIG}"
chmod 640 "${CONFIG}"

# Create systemd unit
cat > /etc/systemd/system/odoo.service <<EOF
[Unit]
Description=Odoo SaaS Service
Documentation=https://www.odoo.com/documentation
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
WorkingDirectory=${ODOO_DIR}
ExecStart=${ODOO_VENV}/bin/python ${ODOO_DIR}/odoo-bin --config=${CONFIG}
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable odoo

echo "============================================"
echo "Odoo SaaS installation complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Edit configuration: nano ${CONFIG}"
echo "2. Update master password in config file"
echo "3. Start Odoo: systemctl start odoo"
echo "4. Check status: systemctl status odoo"
echo "5. View logs: journalctl -u odoo -f"
echo ""
echo "Default ports:"
echo "- HTTP: 8069"
echo "- Longpolling: 8072"
echo ""
echo "Remember to:"
echo "- Configure Nginx reverse proxy"
echo "- Set up SSL certificates"
echo "- Install the Admin Dashboard"