# Operations — Jobs & Scaling

## RQ Queue
`odoo_admin_jobs` processed by worker containers/pods.

## Docker
```bash
docker compose up -d --scale admin_workers=5
```

## Kubernetes (KEDA)
Apply ScaledObject in `k8s/30-admin/` to scale by Redis backlog. Tune `listLength`, `minReplicaCount`, `maxReplicaCount`.

## Job Results
Admin → Jobs → Status, logs, and results. Alerts on failures.
