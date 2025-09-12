# Quick Start — Docker Deployment

This guide will help you launch the Odoo SaaS platform using **Docker Compose** for local development or small-scale production.

---

## Prerequisites
- **Docker Engine** v20.10+
- **Docker Compose** v2.20+
- DNS A records pointing to:
  - `odoo.example.com` (Odoo frontend)
  - `admin.odoo.example.com` (Admin UI)

---

## 1) Clone Repository
```bash
git clone https://your-repo/odoo-saas.git
cd odoo-saas
```

## 2) Configure `.env`
```env
PG_USER=odoo
PG_PASSWORD=strongpassword
DOMAIN=odoo.example.com
ADMIN_DOMAIN=admin.odoo.example.com
```

## 3) Launch Services
```bash
docker compose up -d --build
docker ps
```

## 4) Scale Workers
```bash
docker compose up -d --scale admin_workers=5
```

## 5) TLS (Let's Encrypt)
**HTTP-01 (webroot)**:
```bash
bash scripts/letsencrypt_webroot.sh         # issue
bash scripts/letsencrypt_webroot.sh renew   # renew
```
**DNS-01 (Cloudflare wildcard)**:
```bash
export CLOUDFLARE_API_TOKEN=your_cloudflare_token  # see cloudflare.ini.example

bash scripts/letsencrypt_cloudflare_wildcard.sh         # issue
bash scripts/letsencrypt_cloudflare_wildcard.sh renew   # renew

bash scripts/letsencrypt_cloudflare_wildcard.sh

```

## 6) Verify
- Odoo → `https://odoo.example.com`
- Admin → `https://admin.odoo.example.com`

## 7) Create First Tenant
Admin → **Tenants → Create** → DB name → Save

## 8) Backup/Restore Test
Queue a backup and restore to verify S3 & KMS wiring.

---

## Troubleshooting
- Postgres logs: `docker logs odoo_pg`
- Nginx config test: `docker exec -it odoo_nginx nginx -t`
- Admin health: `docker logs odoo_admin`
