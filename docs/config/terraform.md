# Terraform — S3 + KMS + Lifecycle (and IRSA)

Provision S3 with KMS encryption and lifecycle retention; attach least-privilege IAM for the Admin app (optionally via IRSA).

## Variables
- `bucket_name`, `aws_region`, `kms_key_alias`, `lifecycle_days`, `app_principal_arn`

## Apply
```bash
cd terraform
terraform init
terraform apply   -var="bucket_name=odoo-saas-backups-prod-1234"   -var="aws_region=us-east-1"   -var="kms_key_alias=odoo-saas-backups"   -var="lifecycle_days=30"   -var="app_principal_arn=arn:aws:iam::123456789012:role/odoo-admin-app"
```

## Environment
```env
AWS_REGION=us-east-1
S3_BUCKET=odoo-saas-backups-prod-1234
S3_PREFIX=tenants
S3_SSE=aws:kms
S3_KMS_KEY_ID=<kms_key_arn>
S3_LIFECYCLE_DAYS=30
```
