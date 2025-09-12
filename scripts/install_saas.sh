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
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git python3 python3-venv python3-pip python3-dev \
  postgresql nginx libpq-dev build-essential wkhtmltopdf \
  libev-dev libc-ares-dev libldap2-dev libsasl2-dev \
  libssl-dev

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

# Odoo's requirements pin an old gevent version incompatible with Python 3.10.
# Remove this pin so our preinstalled gevent wheel is kept.
sudo -u "${ODOO_USER}" bash -lc "\
  sed -i '/^gevent==/d' '${ODOO_DIR}/requirements.txt' \
"

# Python venv
sudo -u "${ODOO_USER}" python3 -m venv "${ODOO_VENV}"

# Upgrade/pin build tooling to avoid Cython 3 incompatibilities with old extensions
sudo -u "${ODOO_USER}" bash -lc "\
  ${ODOO_VENV}/bin/pip install -U 'pip<25' wheel 'setuptools<68' 'Cython<3' \
"

# Pre-install greenlet and a gevent version that ships wheels for Python 3.10 (no Cython build)
sudo -u "${ODOO_USER}" bash -lc "\
  ${ODOO_VENV}/bin/pip install 'greenlet>=2.0.2' 'gevent==22.10.2' \
"

# Install remaining Odoo requirements; disable build isolation so our toolchain is used if any build occurs
sudo -u "${ODOO_USER}" bash -lc "\
  cd '${ODOO_DIR}' && PIP_NO_BUILD_ISOLATION=1 ${ODOO_VENV}/bin/pip install -r requirements.txt \
"

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
