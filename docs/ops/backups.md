# Operations — Backups & Restores

## Backups
- `pg_dump -Fc` per tenant
- S3 path: `s3://<bucket>/tenants/<db>/YYYY/MM/DD/HHMMSS.dump`
- SSE-KMS enforced

## On-demand
Admin → Tenant → Backup → enqueues job → alert on result.

## Restore
Admin → Tenant → Restore → From S3 key → To target DB (prefer new DB) → job runs `pg_restore`.

## Best Practices
Schedule nightly backups and test restores in staging.
