# Kubernetes — EKS IRSA

Use Terraform to create IAM role trust for your cluster's OIDC provider and annotate `admin-sa` ServiceAccount. Set `serviceAccountName` in Admin & Workers Deployments and remove static AWS keys from secrets.
