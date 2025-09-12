# Kubernetes — Autoscaling (KEDA)

## RQ Workers
ScaledObject scales worker Deployment by Redis backlog (`rq:queue:odoo_admin_jobs`).

## Longpoll (Optional)
Prometheus-based scaler using NGINX request rates to `/longpolling/` targets the `odoo-longpoll` Deployment.

## Requirements
KEDA installed; Prometheus available for longpoll scaler.
