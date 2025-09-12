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

if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y git python3 python3-venv python3-pip postgresql nginx libpq-dev build-essential wkhtmltopdf

# System user and folders
id -u "${ODOO_USER}" &>/dev/null || adduser --system --quiet --home "${ODOO_HOME}" --group "${ODOO_USER}"
mkdir -p "${LOG_DIR}" "${ODOO_HOME}/custom-addons"
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

# PostgreSQL
systemctl enable --now postgresql
sudo -u postgres createuser -s "${ODOO_USER}" || true

# Fetch Odoo sources
if [[ ! -d "${ODOO_DIR}" ]]; then
  sudo -u "${ODOO_USER}" git clone --depth=1 --branch "${ODOO_VERSION}" https://github.com/odoo/odoo.git "${ODOO_DIR}"
fi

# Python venv
sudo -u "${ODOO_USER}" python3 -m venv "${ODOO_VENV}"
sudo -u "${ODOO_USER}" bash -lc "${ODOO_VENV}/bin/pip install --upgrade pip wheel setuptools"
sudo -u "${ODOO_USER}" bash -lc "cd '${ODOO_DIR}' && ${ODOO_VENV}/bin/pip install -r requirements.txt"

# Odoo config
cat > "${CONFIG}" <<EOF
[options]
admin_passwd = changeme_master
db_host = False
db_port = False
db_user = ${ODOO_USER}
addons_path = ${ODOO_DIR}/addons,${ODOO_HOME}/custom-addons
logfile = ${LOG_DIR}/odoo.log
dbfilter = ^%d$
proxy_mode = True
limit_time_cpu = 120
limit_time_real = 240
EOF

# systemd unit
cat > /etc/systemd/system/odoo.service <<EOF
[Unit]
Description=Odoo SaaS Service
After=network.target postgresql.service

[Service]
User=${ODOO_USER}
Group=${ODOO_USER}
WorkingDirectory=${ODOO_DIR}
ExecStart=${ODOO_VENV}/bin/python ${ODOO_DIR}/odoo-bin --config=${CONFIG}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now odoo

echo "Odoo SaaS installation complete."
echo "Remember to configure Nginx and HTTPS."
