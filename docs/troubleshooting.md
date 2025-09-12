# Troubleshooting

## Ingress 404/502
Verify DNS, Ingress rules, and pod readiness.

## Backup Failures
Check S3 bucket, region, KMS key, IAM policy, and egress. Validate `aws sts get-caller-identity` when using IRSA.

## Webhook 403
Stripe signing secret or Paddle public key mismatch.

## Workers Not Scaling
Check KEDA CRDs, ScaledObject status, Redis connectivity.

## Quota Mismatch
Reindex or `VACUUM FULL`; verify `pg_database_size()` metrics job.
