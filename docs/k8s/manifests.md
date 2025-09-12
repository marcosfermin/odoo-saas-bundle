# Kubernetes — Manifests

Apply in order:
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
