# Nginx & TLS

## Docker (Nginx)

- `config/nginx/site.conf` — Odoo vhost (8069) and dedicated Admin vhost (9090); upstreams point to the Docker services (`odoo`, `admin`) and should be changed to `127.0.0.1` for host deployments
- `config/nginx/site.longpoll.conf` — adds `/longpolling/` to 8072 and Admin vhost; upstreams also point to the Docker services


- `config/nginx/site.conf` — Odoo vhost (8069) and dedicated Admin vhost (9090); upstreams use 127.0.0.1
- `config/nginx/site.longpoll.conf` — adds `/longpolling/` to 8072 and Admin vhost


- `config/nginx/site.conf` — Odoo vhost (8069) and dedicated Admin vhost (9090); upstreams use 127.0.0.1
- `config/nginx/site.longpoll.conf` — adds `/longpolling/` to 8072 and Admin vhost
- `config/nginx/site.conf` — default HTTPS site for Odoo (8069) + Admin (9090); upstreams use 127.0.0.1
- `config/nginx/site.longpoll.conf` — routes `/longpolling/` to 8072


- Basic auth snippet for Admin: `config/nginx/snippets/admin_basic_auth.conf`

### TLS (Let's Encrypt)
**Webroot**:
```bash
bash scripts/letsencrypt_webroot.sh           # issue
bash scripts/letsencrypt_webroot.sh renew     # renew
```
**Cloudflare DNS-01 (wildcard)**:
```bash
export CLOUDFLARE_API_TOKEN=your_token  # see cloudflare.ini.example
bash scripts/letsencrypt_cloudflare_wildcard.sh           # issue
bash scripts/letsencrypt_cloudflare_wildcard.sh renew     # renew

bash scripts/letsencrypt_cloudflare_wildcard.sh           # issue
bash scripts/letsencrypt_cloudflare_wildcard.sh renew     # renew

bash scripts/letsencrypt_cloudflare_wildcard.sh

```

## Kubernetes (Ingress + cert-manager)
- Issuer: `k8s/01-clusterissuer-letsencrypt.yaml`
- Ingress hosts: `k8s/90-ingress.yaml`
- Verify certificate status:
```bash
kubectl describe certificate -n odoo-saas
```
