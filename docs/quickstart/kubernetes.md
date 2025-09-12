# Quick Start — Kubernetes Deployment

Deploy to a Kubernetes cluster for high availability and scaling.

---

## Prerequisites
- Cluster (EKS/AKS/GKE/OKE)
- kubectl & Helm
- NGINX Ingress Controller
- cert-manager (ClusterIssuer)
- External Postgres (e.g., RDS)

## Apply Order
```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-clusterissuer-letsencrypt.yaml
kubectl apply -f k8s/02-configmaps/ -R
kubectl apply -f k8s/03-secrets/ -R
kubectl apply -f k8s/10-redis/ -R
kubectl apply -f k8s/20-odoo/ -R
kubectl apply -f k8s/30-admin/ -R
kubectl apply -f k8s/40-odoo-hpa.yaml
kubectl apply -f k8s/90-ingress.yaml
```

## Scaling
- Odoo: `kubectl scale deploy odoo-main --replicas=3 -n odoo-saas`
- Workers: KEDA ScaledObject in `k8s/30-admin/`

## Storage (RWX)
Apply one of: AWS EFS, Azure Files, GKE Filestore, OCI FSS manifests under `k8s/storage/`.

## Observability
Apply metrics exporters & Grafana dashboards in `k8s/metrics/` and `k8s/grafana/`.
