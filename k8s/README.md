# Apply order

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-clusterissuer-letsencrypt.yaml
kubectl apply -f k8s/02-configmaps/ -R
kubectl apply -f k8s/03-secrets/ -R
kubectl apply -f k8s/10-redis/ -R
# Optional: kubectl apply -f k8s/50-postgres/ -R
kubectl apply -f k8s/20-odoo/ -R
kubectl apply -f k8s/30-admin/ -R
kubectl apply -f k8s/40-odoo-hpa.yaml
kubectl apply -f k8s/90-ingress.yaml
```

## Notes & production tips

TLS: The Ingress assumes nginx-ingress and cert-manager are already installed.

Filestore: For multiple Odoo replicas you need a shared RWX volume (e.g., AWS EFS) for /var/lib/odoo. Replace the PVC with an RWX-capable StorageClass or an NFS provisioner.

Secrets: In production, prefer IRSA (EKS) or an external secrets operator (e.g., External Secrets / Vault) over storing AWS creds in Secrets.

Scaling: HPA is CPU-based. For RQ workers, consider KEDA to scale on Redis queue depth.

Nginx vs Ingress: These manifests use the NGINX Ingress Controller (recommended in K8s) rather than running your own Nginx Deployment.