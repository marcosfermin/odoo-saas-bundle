#!/usr/bin/env bash
set -euo pipefail

# === Admin Dashboard installer ===
ADMIN_DIR="/opt/odoo-admin"
APP_FILE="${ADMIN_DIR}/admin_dashboard.py"
VENV="${ADMIN_DIR}/venv"
PORT="${PORT:-9090}"
ODOO_USER="${ODOO_USER:-odoo}"
ODOO_DIR="/opt/${ODOO_USER}/odoo-16.0"
ODOO_VENV="/opt/${ODOO_USER}/venv"
LOG_FILE="/opt/${ODOO_USER}/logs/odoo.log"
DOMAIN="${DOMAIN:-odoo.example.com}"
REDIS_PORT="${REDIS_PORT:-6379}"
WORKER_COUNT="${WORKER_COUNT:-3}"

if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3-venv python3-pip python3-dev build-essential \
  git acl redis-server apache2-utils libffi-dev libssl-dev

mkdir -p "${ADMIN_DIR}"
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install --upgrade pip wheel
"${VENV}/bin/pip" install \
  flask itsdangerous python-dotenv flask_sqlalchemy flask_login bcrypt redis rq requests \
  boto3 botocore stripe==9.* pycryptodome cryptography

# .env bootstrap
cat > "${ADMIN_DIR}/.env" <<EOF
SECRET_KEY=$(openssl rand -hex 32)
BOOTSTRAP_EMAIL=owner@${DOMAIN}
BOOTSTRAP_PASSWORD=change_me_owner
ODOO_USER=${ODOO_USER}
ODOO_DIR=${ODOO_DIR}
ODOO_BIN=${ODOO_DIR}/odoo-bin
ODOO_VENV=${ODOO_VENV}
ODOO_LOG=${LOG_FILE}
ODOO_SERVICE=odoo
DOMAIN=${DOMAIN}
PORT=${PORT}
REDIS_URL=redis://127.0.0.1:${REDIS_PORT}/0
WEBHOOK_SECRET=$(openssl rand -hex 16)
STRIPE_SIGNING_SECRET=whsec_your_endpoint_secret
PADDLE_PUBLIC_KEY_BASE64=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=us-east-1
S3_BUCKET=odoo-saas-backups
S3_PREFIX=tenants
S3_SSE=aws:kms
S3_KMS_KEY_ID=
S3_LIFECYCLE_DAYS=30
SLACK_WEBHOOK_URL=
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
ALERT_EMAIL_TO=alerts@${DOMAIN}
ALERT_EMAIL_FROM=odoo-admin@${DOMAIN}
EOF

# Place app if shipped alongside
if [[ -f "$(dirname "$0")/../app/admin_dashboard.py" ]]; then
  cp "$(dirname "$0")/../app/admin_dashboard.py" "${APP_FILE}"
fi

# systemd units
cat > /etc/systemd/system/odoo-admin.service <<EOF
[Unit]
Description=Odoo SaaS Admin Dashboard (Flask)
After=network.target redis-server.service

[Service]
Type=simple
User=root
WorkingDirectory=${ADMIN_DIR}
Environment="PYTHONUNBUFFERED=1"
EnvironmentFile=${ADMIN_DIR}/.env
ExecStart=${VENV}/bin/python ${APP_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/odoo-admin-worker@.service <<'EOF'
[Unit]
Description=Odoo SaaS Admin RQ Worker %i
After=network.target redis-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/odoo-admin
EnvironmentFile=/opt/odoo-admin/.env
ExecStart=/bin/bash -lc '/opt/odoo-admin/venv/bin/rq worker -u ${REDIS_URL} odoo_admin_jobs'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Nginx basic auth snippet
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/admin_basic_auth.conf <<'EOF'
auth_basic "Restricted";
auth_basic_user_file /etc/nginx/.admin_htpasswd;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;
EOF

if [[ ! -f /etc/nginx/.admin_htpasswd ]]; then
  htpasswd -c /etc/nginx/.admin_htpasswd admin || true
fi

systemctl daemon-reload
systemctl enable --now redis-server odoo-admin
for i in $(seq 1 "${WORKER_COUNT}"); do
  systemctl enable --now odoo-admin-worker@"${i}"
done

setfacl -m u:root:r /opt/"${ODOO_USER}"/logs/odoo.log || true

echo "Admin installed. Edit ${ADMIN_DIR}/.env and restart: systemctl restart odoo-admin"
