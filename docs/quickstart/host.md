# Quick Start — Host Installation

Install directly on a Linux host without Docker.

---

## Supported OS
- Ubuntu 22.04 LTS
- Debian 11+
- Rocky Linux 9+

## 1) Dependencies
```bash
sudo apt update && sudo apt install -y   python3-venv python3-pip git postgresql redis-server nginx certbot
```

## 2) Install Odoo
```bash
sudo bash scripts/install_saas.sh   # installs OpenLDAP/SASL/SSL build deps
```

## 3) Install Admin Dashboard
```bash
sudo bash scripts/install_admin.sh
sudo nano /opt/odoo-admin/.env
```

## 4) Nginx
```bash
# upstreams default to localhost
sudo cp config/nginx/site.conf /etc/nginx/sites-available/odoo_saas.conf
sudo ln -sf /etc/nginx/sites-available/odoo_saas.conf /etc/nginx/sites-enabled/odoo_saas.conf
sudo nginx -t && sudo systemctl reload nginx
```

## 5) Enable Services
```bash
sudo systemctl enable --now odoo odoo-admin
sudo systemctl enable --now odoo-admin-worker@1
```

## 6) TLS Certificates
```bash
sudo bash scripts/letsencrypt_webroot.sh
# or
sudo CLOUDFLARE_API_TOKEN=your_token bash scripts/letsencrypt_cloudflare_wildcard.sh   # see cloudflare.ini.example
```

## 7) Verify
- Odoo: `https://odoo.example.com`
- Admin: `https://admin.odoo.example.com`

## 8) Demo Tenant
```bash
sudo ODOO_USER=odoo ODOO_DIR=/opt/odoo/odoo-16.0 ODOO_VENV=/opt/odoo/venv   bash scripts/bootstrap_demo.sh demo
```

---

## Troubleshooting
- Odoo logs: `/var/log/odoo/odoo.log`
- Admin logs: `/var/log/odoo-admin.log`
- Worker logs: `journalctl -u odoo-admin-worker@1`
