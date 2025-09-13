#!/usr/bin/env bash
set -euo pipefail

# Configuration
DOMAINS=("odoo.example.com" "admin.odoo.example.com")
EMAIL="${EMAIL:-admin@odoo.example.com}"
STAGING="${STAGING:-0}"

# Paths
LE_DIR="$(pwd)/letsencrypt"
WEBROOT_DIR="$(pwd)/certbot-www"

# Create directories
mkdir -p "$LE_DIR" "$WEBROOT_DIR"

# Staging argument for testing
STAGING_ARG=""
if [[ "$STAGING" -eq 1 ]]; then
    STAGING_ARG="--staging"
    echo "Using Let's Encrypt staging server"
fi

# Build domain arguments
DOMAIN_ARGS=()
for d in "${DOMAINS[@]}"; do
    DOMAIN_ARGS+=("-d" "$d")
done

# Command (issue or renew)
CMD="${1:-issue}"

if [[ "$CMD" == "renew" ]]; then
    echo "Renewing certificates..."
    docker run --rm \
        -v "$LE_DIR:/etc/letsencrypt" \
        -v "$WEBROOT_DIR:/var/www/certbot" \
        certbot/certbot:latest renew --quiet
    echo "Certificate renewal complete"
else
    echo "Issuing certificates for: ${DOMAINS[*]}"
    docker run --rm -it \
        -v "$LE_DIR:/etc/letsencrypt" \
        -v "$WEBROOT_DIR:/var/www/certbot" \
        certbot/certbot:latest certonly \
            --webroot \
            -w /var/www/certbot \
            --email "$EMAIL" \
            --agree-tos \
            --no-eff-email \
            $STAGING_ARG \
            "${DOMAIN_ARGS[@]}"
    echo "Certificates issued successfully"
fi

# Reload nginx if running in Docker
if docker compose ps nginx &>/dev/null; then
    echo "Reloading nginx configuration..."
    docker compose exec nginx nginx -t && \
    docker compose exec nginx nginx -s reload
    echo "Nginx reloaded"
fi

echo "Done!"