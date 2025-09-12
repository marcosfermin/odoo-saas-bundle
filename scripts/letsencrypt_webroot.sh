#!/usr/bin/env bash
set -euo pipefail

DOMAINS=("odoo.example.com" "admin.odoo.example.com")
EMAIL="admin@odoo.example.com"
STAGING=0

LE_DIR="$(pwd)/letsencrypt"
WEBROOT_DIR="$(pwd)/certbot-www"

mkdir -p "$LE_DIR" "$WEBROOT_DIR"

STAGING_ARG=""
if [[ "$STAGING" -eq 1 ]]; then
  STAGING_ARG="--staging"
fi

DOMAIN_ARGS=()
for d in "${DOMAINS[@]}"; do
  DOMAIN_ARGS+=("-d" "$d")
done

docker run --rm \
  -v "$LE_DIR:/etc/letsencrypt" \
  -v "$WEBROOT_DIR:/var/www/certbot" \
  certbot/certbot:latest certonly \
    --webroot -w /var/www/certbot \
    --email "$EMAIL" --agree-tos --no-eff-email \
    $STAGING_ARG \
    "${DOMAIN_ARGS[@]}"

docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
