# Security

- TLS throughout (Ingress/Nginx)
- RBAC (Owner/Admin/Viewer) with per-action checks
- Audit logging for sensitive ops
- Stripe/Paddle signature verification
- Least-privilege IAM with KMS/S3; prefer IRSA
- Containers: read-only FS where possible; drop capabilities
- Network: restrict egress to S3/SMTP/Stripe/Paddle
