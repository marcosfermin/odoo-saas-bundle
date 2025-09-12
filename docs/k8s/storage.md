# Kubernetes — RWX Storage

Use one of the provided manifests for `/var/lib/odoo` shared storage:
- AWS EFS (EKS) → `k8s/storage/aws-efs.yaml`
- Azure Files (AKS) → `k8s/storage/azure-files.yaml`
- GKE Filestore → `k8s/storage/gke-filestore.yaml`
- OCI FSS (OKE) → `k8s/storage/oci-fss.yaml`
