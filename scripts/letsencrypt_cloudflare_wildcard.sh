#!/usr/bin/env bash
set -euo pipefail

DOMAIN="odoo.example.com"
EMAIL="admin@odoo.example.com"
STAGING=0

LE_DIR="$(pwd)/letsencrypt"
mkdir -p "$LE_DIR"

CF_CREDS="$(pwd)/cloudflare.ini"
cat > "$CF_CREDS" <<EOF
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF
chmod 600 "$CF_CREDS"

STAGING_ARG=""
if [[ "$STAGING" -eq 1 ]]; then
  STAGING_ARG="--staging"
fi

docker run --rm \
  -v "$LE_DIR:/etc/letsencrypt" \
  -v "$CF_CREDS:/cloudflare.ini" \
  certbot/dns-cloudflare:latest certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /cloudflare.ini \
    --email "$EMAIL" --agree-tos --no-eff-email \
    $STAGING_ARG \
    -d "$DOMAIN" -d "*.$DOMAIN"

docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
