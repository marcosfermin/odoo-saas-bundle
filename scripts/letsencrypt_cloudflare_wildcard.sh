#!/usr/bin/env bash
set -euo pipefail

# Configuration
DOMAIN="${DOMAIN:-odoo.example.com}"
EMAIL="${EMAIL:-admin@odoo.example.com}"
STAGING="${STAGING:-0}"

# Check for required environment variable
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo "Error: CLOUDFLARE_API_TOKEN environment variable is required"
    echo "Usage: CLOUDFLARE_API_TOKEN=your_token $0 [issue|renew]"
    exit 1
fi

# Paths
LE_DIR="$(pwd)/letsencrypt"
CF_CREDS="$(pwd)/cloudflare.ini"

# Create directories
mkdir -p "$LE_DIR"

# Create Cloudflare credentials file
cat > "$CF_CREDS" <<EOF
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF
chmod 600 "$CF_CREDS"

# Staging argument for testing
STAGING_ARG=""
if [[ "$STAGING" -eq 1 ]]; then
    STAGING_ARG="--staging"
    echo "Using Let's Encrypt staging server"
fi

# Command (issue or renew)
CMD="${1:-issue}"

if [[ "$CMD" == "renew" ]]; then
    echo "Renewing certificates..."
    docker run --rm \
        -v "$LE_DIR:/etc/letsencrypt" \
        -v "$CF_CREDS:/cloudflare.ini:ro" \
        certbot/dns-cloudflare:latest renew --quiet
    echo "Certificate renewal complete"
else
    echo "Issuing new wildcard certificate for $DOMAIN..."
    docker run --rm -it \
        -v "$LE_DIR:/etc/letsencrypt" \
        -v "$CF_CREDS:/cloudflare.ini:ro" \
        certbot/dns-cloudflare:latest certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials /cloudflare.ini \
            --email "$EMAIL" \
            --agree-tos \
            --no-eff-email \
            $STAGING_ARG \
            -d "$DOMAIN" \
            -d "*.$DOMAIN" \
            -d "admin.$DOMAIN"
    echo "Certificate issued successfully"
fi

# Clean up credentials file
rm -f "$CF_CREDS"

# Reload nginx if running in Docker
if docker compose ps nginx &>/dev/null; then
    echo "Reloading nginx configuration..."
    docker compose exec nginx nginx -t && \
    docker compose exec nginx nginx -s reload
    echo "Nginx reloaded"
fi

echo "Done!"
