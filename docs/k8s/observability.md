# Kubernetes — Observability

## Exporters
- RQ exporter Deployment + Service + ServiceMonitor
- Odoo exporter sidecar + ServiceMonitor
- Ingress NGINX metrics

## Grafana
Dashboards in `k8s/grafana/dashboards/` auto-import via sidecar label.

## Alerts
Add Prometheus alerts for queue depth, job failures, and ingress 5xx.
