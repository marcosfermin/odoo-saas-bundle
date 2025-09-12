# Architecture

The Odoo SaaS Platform uses a **modular microservices design** with Docker or Kubernetes to provide scalability, high availability, and security.

---

## Core Components

| Component      | Purpose |
|----------------|---------|
| **Odoo**       | Primary application providing ERP capabilities to tenants. |
| **PostgreSQL** | Multi-tenant database backend with strict DB-level isolation. |
| **Redis + RQ** | Job queue for background tasks such as backups, restores, module upgrades. |
| **Admin Dashboard** | Flask-based UI to manage tenants, quotas, modules, and billing. |
| **Nginx**      | Reverse proxy with SSL termination and routing for Odoo and Admin UI. |
| **S3 Bucket**  | Storage backend for encrypted backups with lifecycle policies. |
| **Stripe/Paddle** | Billing systems integrated via secure webhooks. |

---

## Data Flow

1. **User Access** — A customer accesses Odoo via the tenant-specific domain. Nginx routes traffic to the correct Odoo service.
2. **Tenant Management** — Admin UI creates, suspends, or deletes tenants. Each tenant's database is created or managed via background jobs.
3. **Backups** — Nightly or on-demand backups run as RQ jobs and upload to S3 with server-side encryption using KMS.
4. **Billing Integration** — Stripe or Paddle sends webhook events; failed payments trigger automatic tenant suspension.

---

## Deployment Models

| Deployment Mode | When to Use |
|-----------------|-------------|
| **Docker Compose** | Development or single-server production. |
| **Kubernetes (K8s)** | Production clusters with HA, scaling, and cloud-native features. |

---

## High Availability (K8s)

- Odoo scaled horizontally behind Kubernetes Services.
- RQ workers autoscaled with KEDA based on queue depth.
- Longpolling workers separated to improve performance.
- Postgres hosted via managed DB (e.g., AWS RDS).
- Backups and filestore stored in RWX volume like EFS.

---

## Security Layers

- TLS termination at ingress.
- AWS IAM roles via IRSA for S3/KMS.
- RBAC roles in Admin Dashboard (Owner/Admin/Viewer).
- Audit logging for every admin action.
- Webhook signature verification: Stripe (HMAC), Paddle (RSA).

---

## Monitoring and Observability

- **Prometheus** scrapes metrics from Odoo Exporter, RQ Exporter, and Nginx Ingress Controller.
- **Grafana Dashboards** provided in `k8s/grafana/dashboards/`.
