# Odoo SaaS + Admin Dashboard (Complete Bundle)

A production-ready multi-tenant Odoo deployment with an Admin Dashboard for:
- Tenant CRUD, quotas & usage metrics (DB size, active users)
- Per-tenant S3 backups (KMS encryption + lifecycle) & restores
- Module install/upgrade queue
- Multi-worker background jobs (RQ) with job result pages
- Stripe/Paddle webhook signature verification
- Alerts via Email/Slack
- Role-based access + audit log
- Docker & systemd installs, Nginx reverse proxy, Let’s Encrypt automation
- **Kubernetes manifests** (Odoo + Admin + Redis + Ingress + cert-manager)
- **KEDA autoscaling** for RQ workers by Redis queue depth
- **Cloud RWX filestore** manifests for AWS / Azure / Google Cloud / Oracle Cloud

---

## What’s here

- `scripts/install_saas.sh` – Full Odoo multi-tenant (host) installer (installs OpenLDAP/SASL/SSL build deps)
- `scripts/install_admin.sh` – Admin Dashboard (Flask) host installer
- `scripts/bootstrap_demo.sh` – Create a demo tenant DB + modules
- `app/admin_dashboard.py` – Complete Admin app
- `config/.env.example` – Env template
- `cloudflare.ini.example` – Cloudflare API token template
- `config/nginx/*` – Nginx site/snippet (host & Docker variants; upstreams default to 127.0.0.1)
- `systemd/*` – Systemd units for Admin + workers  
- `docker-compose.yml` – Postgres + Odoo + Admin + Redis + Nginx  
- `docker-compose.override.yml` – gevent longpolling + Odoo workers scaling  
- `docker-compose.prod.yml` – resource limits, logs, read-only FS where possible  
- `scripts/letsencrypt_webroot.sh` – HTTP-01 (non-wildcard) LE automation  
- `scripts/letsencrypt_cloudflare_wildcard.sh` – DNS-01 wildcard (Cloudflare)  
- `terraform/odoo_s3_kms_lifecycle.tf` – **Terraform** for S3 + KMS + lifecycle  
- **Kubernetes** in `k8s/`:
  - `00-namespace.yaml`, `01-clusterissuer-letsencrypt.yaml`
  - `02-configmaps/` (Odoo/Admin), `03-secrets/` (basic-auth + app secrets)
  - `10-redis/` (StatefulSet + Service)
  - `20-odoo/` (Deployment + Service + RWX PVC)
  - `30-admin/` (Admin + Workers + Service)
  - `40-odoo-hpa.yaml`, `90-ingress.yaml`
  - `30-admin/admin-workers-keda.yaml` (**KEDA ScaledObject** for queue autoscaling)
  - `storage/` (**RWX PVCs**): `aws-efs.yaml`, `azure-files.yaml`, `gke-filestore.yaml`, `oci-fss.yaml`
  - Optional Postgres in `50-postgres/` (StatefulSet + Service)

---

## Quick starts

### Host (non-Docker)

Deploy directly on a Linux host without containers.

1. **Install Odoo and its dependencies**
   ```bash
   sudo bash scripts/install_saas.sh
   ```
2. **Install the Admin Dashboard and create its environment file**
   ```bash
   sudo bash scripts/install_admin.sh
   sudo nano /opt/odoo-admin/.env   # fill Stripe/Paddle/S3/alerts/etc.
   ```
3. **Enable and start services**
   ```bash
   sudo systemctl enable --now odoo odoo-admin
   sudo systemctl enable --now odoo-admin-worker@1
   ```
4. **Configure Nginx (upstreams default to localhost)**
   ```bash
   sudo cp config/nginx/site.conf /etc/nginx/sites-available/odoo_saas.conf
   sudo ln -sf /etc/nginx/sites-available/odoo_saas.conf /etc/nginx/sites-enabled/odoo_saas.conf
   sudo nginx -t && sudo systemctl reload nginx
   ```
5. **Obtain TLS certificates**
   ```bash
   sudo bash scripts/letsencrypt_webroot.sh
   # OR
   sudo CLOUDFLARE_API_TOKEN=your_token bash scripts/letsencrypt_cloudflare_wildcard.sh   # see cloudflare.ini.example
   ```
6. **(Optional) Bootstrap a demo tenant**
   ```bash
   sudo ODOO_USER=odoo ODOO_DIR=/opt/odoo/odoo-16.0 ODOO_VENV=/opt/odoo/venv bash scripts/bootstrap_demo.sh demo
   ```
=======

### Docker (recommended)

```bash
mkdir -p admin config/odoo config/nginx/snippets config/nginx custom-addons
# Add files (this repo).
docker compose run --rm nginx sh -c 'apk add --no-cache apache2-utils && htpasswd -c /etc/nginx/.admin_htpasswd admin'
docker compose up -d --build

# TLS (choose one)
bash scripts/letsencrypt_webroot.sh
# OR
export CLOUDFLARE_API_TOKEN=your_token  # see cloudflare.ini.example
bash scripts/letsencrypt_cloudflare_wildcard.sh

# Optional gevent + worker scaling
docker compose up -d --build
docker compose up -d --scale admin_workers=5

# Optional prod hardening
docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.prod.yml up -d --build
```

---

## Terraform: S3 + KMS + Lifecycle

Use `terraform/odoo_s3_kms_lifecycle.tf` to create:

- Private S3 bucket, default SSE-KMS, versioning
- Lifecycle expiration under `tenants/`
- Bucket policy (TLS + KMS)
- IAM policy for the Admin app role/user

```bash
cd terraform
terraform init
terraform apply \
  -var="bucket_name=odoo-saas-backups-prod-1234" \
  -var="aws_region=us-east-1" \
  -var="kms_key_alias=odoo-saas-backups" \
  -var="lifecycle_days=30" \
  -var="app_principal_arn=arn:aws:iam::123456789012:role/odoo-admin-app"
```

Outputs → Admin app env:

```env
AWS_REGION=us-east-1
S3_BUCKET=odoo-saas-backups-prod-1234
S3_PREFIX=tenants
S3_SSE=aws:kms
S3_KMS_KEY_ID=<kms_key_arn>
S3_LIFECYCLE_DAYS=30
```

---

## Kubernetes

### Prereqs

- A cluster (EKS/AKS/GKE/OKE or on-prem)
- **NGINX Ingress Controller** installed
- **cert-manager** installed
- (Recommended) External Postgres (e.g., Amazon RDS or Cloud SQL); optional in-cluster manifest available

### Apply order

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

### KEDA autoscaling for RQ workers

We provide `k8s/30-admin/admin-workers-keda.yaml` which scales `admin-workers` based on **Redis queue depth** (RQ list `rq:queue:odoo_admin_jobs`).
Requirements:

* **KEDA** installed (`kubectl get crd | grep scaledobjects.keda.sh`)
* Redis reachable at `redis.odoo-saas.svc.cluster.local:6379`

Adjust thresholds in the ScaledObject as needed.

### RWX storage (shared filestore for Odoo)

Odoo’s `/var/lib/odoo` must be **shared (RWX)** across replicas. We include four cloud-specific options in `k8s/storage/`:

* `aws-efs.yaml` – **EKS + EFS CSI**, dynamic provisioning with Access Points
* `azure-files.yaml` – **AKS + Azure Files CSI**, dynamic RWX
* `gke-filestore.yaml` – **GKE + Filestore CSI**, dynamic or pre-provisioned
* `oci-fss.yaml` – **Oracle OKE + FSS CSI**, dynamic or static

> Pick **one** and apply it, then ensure the Odoo Deployment mounts `odoo-filestore` PVC (already wired).
> For dynamic provisioning you must have the cloud’s CSI driver installed and, in some cases, the correct controller IAM/permissions.

---

## Security best practices

* Keep TLS on everywhere; rotate Stripe/Paddle secrets regularly
* Prefer cloud-native secret managers (SSM/Secret Manager/KeyVault/Vault)
* Use least-privilege IAM for S3 and KMS (policy included via Terraform)
* In Docker, run with read-only FS where possible (`docker-compose.prod.yml`)
* In K8s, prefer IRSA/Workload Identity over long-lived AWS/GCP keys

---

````

---

# New Kubernetes manifests

## `k8s/30-admin/admin-workers-keda.yaml`
**KEDA ScaledObject** for RQ workers, scaling on Redis queue depth.  
- Targets list `rq:queue:odoo_admin_jobs` (default RQ list name for queue `odoo_admin_jobs`)  
- Scales between 1 and 10 workers based on pending job count

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: admin-workers-queue
  namespace: odoo-saas
spec:
  scaleTargetRef:
    name: admin-workers           # matches k8s/30-admin/admin-workers-deployment.yaml
  pollingInterval: 15             # seconds between checks
  cooldownPeriod: 120             # scale down delay
  minReplicaCount: 1
  maxReplicaCount: 10
  triggers:
    - type: redis
      metadata:
        address: redis.odoo-saas.svc.cluster.local:6379
        listName: rq:queue:odoo_admin_jobs
        listLength: "5"           # scale up when > 5 pending jobs
      # authenticationRef:        # Uncomment if using Redis AUTH
      #   name: redis-auth
---
# Optional TriggerAuthentication if your Redis requires a password:
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: redis-auth
  namespace: odoo-saas
spec:
  secretTargetRef:
    - parameter: password
      name: redis-secret
      key: password
````

> If your Redis is password-protected, create `redis-secret` and uncomment `authenticationRef`, plus add `username`/`password` parameters as required by KEDA’s Redis scaler.

---

## RWX Shared Filestore Manifests

> **Choose the file for your cloud**, customize parameters, and apply.
> After applying, your cluster will have a `StorageClass` called `odoo-rwx` and a `PersistentVolumeClaim` named `odoo-filestore` in the `odoo-saas` namespace that Odoo will mount at `/var/lib/odoo`.

### 1) `k8s/storage/aws-efs.yaml` (EKS + EFS CSI, dynamic)

Prereqs:

- **AWS EFS CSI Driver** installed
- An **EFS File System** already created (record its **FileSystemId**)
- (Recommended) an **Access Point** per workload; below we let the CSI create APs dynamically.

```yaml
# StorageClass for dynamic EFS Access Points
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: odoo-rwx
provisioner: efs.csi.aws.com
parameters:
  # If you want to pin to a specific FS, set fileSystemId; otherwise use a CSI Access Point policy.
  fileSystemId: fs-1234567890abcdef
  provisioningMode: efs-ap
  directoryPerms: "0770"
mountOptions:
  - nolock
  - nfsvers=4.1
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
# Namespace PVC that Odoo uses
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-filestore
  namespace: odoo-saas
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  storageClassName: odoo-rwx
```

> Set `fileSystemId` to your EFS ID. EKS IAM roles for service accounts (IRSA) are not required for basic EFS CSI mounting.

---

### 2) `k8s/storage/azure-files.yaml` (AKS + Azure Files CSI, dynamic)

Prereqs:

- **Azure Files CSI driver** enabled on your AKS cluster
- Cluster identity authorized to create Azure Files shares (default for managed clusters)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: odoo-rwx
provisioner: file.csi.azure.com
allowVolumeExpansion: true
parameters:
  skuName: Standard_LRS         # or Premium_LRS
  protocol: nfs                 # NFS for POSIX semantics (AKS supports this in many regions)
mountOptions:
  - nolock
reclaimPolicy: Retain
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-filestore
  namespace: odoo-saas
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  storageClassName: odoo-rwx
```

> If NFS protocol isn’t available in your region, omit `protocol: nfs` (will use SMB). Odoo works with SMB too, but NFS offers better POSIX behavior.

---

### 3) `k8s/storage/gke-filestore.yaml` (GKE + Filestore CSI)

Prereqs:

- **Filestore CSI Driver** enabled on your GKE cluster
- For **dynamic** provisioning, the CSI can create instances if your cluster/workload identity allows it; otherwise pre-provision a Filestore instance and use a **static** PV.

**Dynamic (recommended if permitted):**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: odoo-rwx
provisioner: filestore.csi.storage.gke.io
allowVolumeExpansion: true
parameters:
  tier: ENTERPRISE           # or STANDARD / ZONAL
  network: default
  protocol: nfs
  # Optional: specify location/zone if needed:
  # location: us-central1
reclaimPolicy: Retain
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-filestore
  namespace: odoo-saas
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  storageClassName: odoo-rwx
```

**Static (use existing Filestore):**

```yaml
# Replace these with your Filestore export IP/path
apiVersion: v1
kind: PersistentVolume
metadata:
  name: odoo-filestore-pv
spec:
  capacity:
    storage: 20Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: 10.0.0.5            # Filestore IP
    path: /odoo-filestore       # Export
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-filestore
  namespace: odoo-saas
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  volumeName: odoo-filestore-pv
```

---

### 4) `k8s/storage/oci-fss.yaml` (Oracle OKE + OCI File Storage Service)

Prereqs:

- **OCI FSS CSI driver** installed
- Dynamic provisioning generally needs proper OCI identities/permissions. If unsure, use **static** PV with your existing **Mount Target IP** and **Export Path**.

**Dynamic (if enabled in your tenancy):**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: odoo-rwx
provisioner: fss.csi.oraclecloud.com
parameters:
  # Set the right OCIDs for your tenancy/network (examples below are placeholders)
  compartmentOcid: ocid1.compartment.oc1..aaaa...xyz
  subnetOcid: ocid1.subnet.oc1..aaaa...xyz
  # Optional: specify mount target subnet or AD; see OCI FSS CSI docs for more params
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-filestore
  namespace: odoo-saas
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  storageClassName: odoo-rwx
```

**Static (using existing Mount Target + Export):**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: odoo-filestore-pv
spec:
  capacity:
    storage: 20Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: 10.0.1.25                # Mount Target IP address
    path: /odoo-filestore            # Export path
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-filestore
  namespace: odoo-saas
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  volumeName: odoo-filestore-pv
```

---

### Final wiring

- After applying your chosen RWX manifest, ensure **Odoo Deployment** mounts `odoo-filestore` at `/var/lib/odoo` (already configured in the provided Odoo manifests).
- For **KEDA**, apply `k8s/30-admin/admin-workers-keda.yaml`. Tune `listLength` and `maxReplicaCount` based on your workload.


## Getting Started

### Documentation
- Full docs live in **`/docs`** (MkDocs). View locally:
  ```bash
  pip install mkdocs mkdocs-material
  mkdocs -f docs/mkdocs.yml serve
  ```
  Or build static site:
  ```bash
  mkdocs -f docs/mkdocs.yml build
  ```

### Quick Start (Docker)
```bash
docker compose up -d --build
# scale RQ workers
docker compose up -d --scale admin_workers=5
```

### Quick Start (Kubernetes)
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

## Post‑Install Checklist

1. **DNS**
   - `odoo.example.com` → your load balancer/host
   - `admin.odoo.example.com` → same

2. **TLS**
   - Docker: run `scripts/letsencrypt_webroot.sh` or the Cloudflare DNS-01 script
   - K8s: cert-manager + `k8s/01-clusterissuer-letsencrypt.yaml`

3. **Billing Webhooks**
   - Stripe: set endpoint to `https://admin.odoo.example.com/webhooks/billing`
     - Set `STRIPE_SIGNING_SECRET`
   - Paddle: upload RSA public key (Base64 → `PADDLE_PUBLIC_KEY_BASE64`)

4. **S3 + KMS**
   - Provision with Terraform in `terraform/`
   - Set `AWS_REGION`, `S3_BUCKET`, `S3_KMS_KEY_ID`, `S3_PREFIX=tenants`, `S3_SSE=aws:kms`
   - Confirm bucket lifecycle retention

5. **Alerts**
   - Slack webhook URL (`SLACK_WEBHOOK_URL`)
   - SMTP (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `ALERT_EMAIL_FROM`, `ALERT_EMAIL_TO`)

6. **RBAC & Security**
   - Change `BOOTSTRAP_PASSWORD` and rotate `SECRET_KEY`
   - Remove any static cloud keys in favor of IRSA/Workload Identity
   - Lock down Nginx Admin Basic Auth (if enabled)
 
## Ubuntu 24.04 Verification

The bundle has been sanity‑checked on **Ubuntu 24.04 LTS**. Basic script syntax was
validated (`bash -n scripts/*.sh`). To verify your environment and the
integrations, run:

```bash
# Docker Compose configuration
docker compose config

# Kubernetes manifests
kubectl apply -f k8s/ --dry-run=client -R

# Terraform module
cd terraform
terraform init
terraform validate
```

Ensure Docker, `kubectl` and Terraform are installed before executing these
checks.

## Documentation

The full documentation is included under **`/docs`** (MkDocs).

Serve locally:
```bash
pip install mkdocs mkdocs-material
mkdocs serve
```
Build static site:
```bash
mkdocs build
```
