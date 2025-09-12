# Configuration — Environment Variables

This page documents all environment variables used by the platform, grouped by component. Variables can be set via Docker Compose, Kubernetes (Secrets/ConfigMaps), or host installs.

## Admin Dashboard (Flask)

| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `SECRET_KEY` | ✅ | — | Strong random key for sessions/CSRF. |
| `BOOTSTRAP_EMAIL` | ✅ | — | Initial Owner account. |
| `BOOTSTRAP_PASSWORD` | ✅ | — | Initial Owner password. |
| `FLASK_ENV` | ❌ | `production` | `production` or `development`. |

## Redis / Jobs
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `REDIS_URL` | ✅ | `redis://redis:6379/0` | RQ backend. |
| `RQ_QUEUE` | ❌ | `odoo_admin_jobs` | Queue name. |

## PostgreSQL (job connections)
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `PG_HOST` | ✅ | `postgres` | Hostname/service. |
| `PG_PORT` | ❌ | `5432` | Port. |
| `PG_USER` | ✅ | `odoo` | Role with rights to manage tenant DBs. |
| `PG_PASSWORD` | ✅ | — | Password. |
| `PG_SSLMODE` | ❌ | `prefer` | `require` for remote DB. |

## S3 Backups
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `AWS_REGION` | ✅ | — | Region. |
| `S3_BUCKET` | ✅ | — | Backup bucket. |
| `S3_PREFIX` | ❌ | `tenants` | Key prefix. |
| `S3_SSE` | ❌ | `aws:kms` | Use KMS. |
| `S3_KMS_KEY_ID` | ✅ | — | KMS key ARN. |
| `S3_LIFECYCLE_DAYS` | ❌ | `30` | Retention. |

## Billing Webhooks
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `STRIPE_SIGNING_SECRET` | ❌ | — | HMAC secret. |
| `PADDLE_PUBLIC_KEY_BASE64` | ❌ | — | RSA public key (Base64). |
| `WEBHOOK_SECRET` | ❌ | — | Fallback header `X-Webhook-Secret`. |

## Alerts
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `SLACK_WEBHOOK_URL` | ❌ | — | Slack alerts. |
| `SMTP_HOST` | ❌ | — | SMTP server. |
| `SMTP_PORT` | ❌ | `587` | Port. |
| `SMTP_USER` | ❌ | — | Username. |
| `SMTP_PASS` | ❌ | — | Password. |
| `ALERT_EMAIL_FROM` | ❌ | `odoo-admin@localhost` | From address. |
| `ALERT_EMAIL_TO` | ❌ | — | To address. |

## Odoo Runtime
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `WORKERS` | ❌ | `4` | Odoo workers. |
| `LIMIT_TIME_CPU` | ❌ | `60` | CPU time per request. |
| `LIMIT_TIME_REAL` | ❌ | `120` | Wall time per request. |

## Domains
| Variable | Required | Default | Notes |
|---------|----------|---------|------|
| `DOMAIN` | ✅ | — | Odoo domain. |
| `ADMIN_DOMAIN` | ✅ | — | Admin domain. |
