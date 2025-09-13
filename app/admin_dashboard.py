import os
import secrets
import subprocess
import shlex
import json
import base64
import smtplib
from email.mime.text import MIMEText
from datetime import datetime
from functools import wraps

from flask import (
    Flask,
    request,
    redirect,
    url_for,
    render_template_string,
    flash,
    abort,
)
from itsdangerous import URLSafeSerializer
from dotenv import load_dotenv
from flask_sqlalchemy import SQLAlchemy
from flask_login import (
    LoginManager,
    UserMixin,
    login_user,
    logout_user,
    current_user,
    login_required,
)
import bcrypt
import redis
from rq import Queue
import boto3
import stripe
from Crypto.PublicKey import RSA
from Crypto.Hash import SHA1
from Crypto.Signature import PKCS1_v1_5

load_dotenv()

APP_SECRET = os.environ.get("SECRET_KEY", secrets.token_hex(32))
PORT = int(os.environ.get("PORT", "9090"))
REDIS_URL = os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")

STRIPE_SIGNING_SECRET = os.environ.get("STRIPE_SIGNING_SECRET", "")
PADDLE_PUB_B64 = os.environ.get("PADDLE_PUBLIC_KEY_BASE64", "")
PADDLE_PUBLIC_KEY = base64.b64decode(PADDLE_PUB_B64).decode() if PADDLE_PUB_B64 else ""

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
S3_PREFIX = os.environ.get("S3_PREFIX", "tenants")
S3_SSE = os.environ.get("S3_SSE", "")
S3_KMS_KEY_ID = os.environ.get("S3_KMS_KEY_ID", "")
S3_LIFECYCLE_DAYS = int(os.environ.get("S3_LIFECYCLE_DAYS", "30"))

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
ALERT_EMAIL_TO = os.environ.get("ALERT_EMAIL_TO", "")
ALERT_EMAIL_FROM = os.environ.get("ALERT_EMAIL_FROM", "odoo-admin@example.com")

ODOO_USER = os.environ.get("ODOO_USER", "odoo")
ODOO_DIR = os.environ.get("ODOO_DIR", f"/opt/{ODOO_USER}/odoo-16.0")
ODOO_BIN = os.environ.get("ODOO_BIN", f"{ODOO_DIR}/odoo-bin")
ODOO_VENV = os.environ.get("ODOO_VENV", f"/opt/{ODOO_USER}/venv")
ODOO_LOG = os.environ.get("ODOO_LOG", f"/opt/{ODOO_USER}/logs/odoo.log")
ODOO_SERVICE = os.environ.get("ODOO_SERVICE", "odoo")
BASE_DOMAIN = os.environ.get("DOMAIN", "odoo.example.com")
BOOTSTRAP_EMAIL = os.environ.get("BOOTSTRAP_EMAIL", "owner@odoo.example.com")
BOOTSTRAP_PASSWORD = os.environ.get("BOOTSTRAP_PASSWORD", "change_me_owner")

# Database path configuration (supports Docker and host environments)
DB_PATH = os.environ.get("ADMIN_DB_PATH", "/opt/odoo-admin/admin.db")
DB_DIR = os.path.dirname(DB_PATH)

app = Flask(__name__)
app.secret_key = APP_SECRET
csrf = URLSafeSerializer(APP_SECRET, salt="csrf-1")

# Ensure database directory exists
if not os.path.exists(DB_DIR):
    os.makedirs(DB_DIR, exist_ok=True)

app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{DB_PATH}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

db = SQLAlchemy(app)
login_mgr = LoginManager(app)

rconn = redis.from_url(REDIS_URL)
q = Queue("odoo_admin_jobs", connection=rconn)

# Initialize S3 client with optional credentials
if os.environ.get("AWS_ACCESS_KEY_ID"):
    s3 = boto3.client("s3", region_name=AWS_REGION)
else:
    # Use IAM role/IRSA
    s3 = boto3.client("s3", region_name=AWS_REGION)


class Role:
    OWNER = "OWNER"
    ADMIN = "ADMIN"
    VIEWER = "VIEWER"


PERMISSIONS = {
    "view_dashboard": {Role.OWNER, Role.ADMIN, Role.VIEWER},
    "create_tenant": {Role.OWNER, Role.ADMIN},
    "delete_tenant": {Role.OWNER},
    "suspend_tenant": {Role.OWNER, Role.ADMIN},
    "set_quota": {Role.OWNER, Role.ADMIN},
    "backup_tenant": {Role.OWNER, Role.ADMIN},
    "restore_tenant": {Role.OWNER, Role.ADMIN},
    "modules_manage": {Role.OWNER, Role.ADMIN},
    "service_control": {Role.OWNER, Role.ADMIN},
    "view_logs": {Role.OWNER, Role.ADMIN},
    "view_audit": {Role.OWNER, Role.ADMIN},
    "manage_users": {Role.OWNER},
}


class User(db.Model, UserMixin):
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(200), unique=True, nullable=False)
    pw_hash = db.Column(db.LargeBinary, nullable=False)
    role = db.Column(db.String(10), nullable=False, default=Role.ADMIN)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class AuditLog(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    actor = db.Column(db.String(200))
    action = db.Column(db.String(200))
    target = db.Column(db.String(200))
    meta = db.Column(db.Text)
    at = db.Column(db.DateTime, default=datetime.utcnow)


class TenantMeta(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    dbname = db.Column(db.String(200), unique=True, nullable=False)
    suspended = db.Column(db.Boolean, default=False)
    quota_gb = db.Column(db.Integer, default=5)
    notes = db.Column(db.Text)


def run(cmd: str, check=True):
    """Execute shell command safely"""
    p = subprocess.run(shlex.split(cmd), capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {cmd}\n{p.stderr}")
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def has_perm(action: str):
    """Check if current user has permission for action"""
    return current_user.is_authenticated and current_user.role in PERMISSIONS.get(
        action, set()
    )


def record(action, target="", meta=None):
    """Record audit log entry"""
    entry = AuditLog(
        actor=(current_user.email if current_user.is_authenticated else "system"),
        action=action,
        target=target,
        meta=json.dumps(meta or {}),
    )
    db.session.add(entry)
    db.session.commit()


def require_perm(action):
    """Decorator to require permission for view"""
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not has_perm(action):
                abort(403)
            return view(*args, **kwargs)
        return wrapper
    return decorator


def get_databases():
    """Get list of tenant databases"""
    query = (
        'psql -tAc "SELECT datname FROM pg_database '
        f"WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname='{ODOO_USER}') "
        "AND datname NOT IN ('postgres','template0','template1') ORDER BY 1;\""
    )
    _, out, _ = run(query)
    return [line for line in out.splitlines() if line]


def db_size_bytes(dbname: str) -> int:
    """Get database size in bytes"""
    q = f"psql -tAc \"SELECT pg_database_size('{dbname}');\""
    _, out, _ = run(q)
    try:
        return int(out.strip())
    except Exception:
        return 0


def active_user_count(dbname: str) -> int:
    """Get active user count for tenant"""
    q = f"psql -tAc \"SELECT COALESCE((SELECT COUNT(*) FROM res_users WHERE active),0) FROM pg_catalog.pg_tables WHERE tablename='res_users';\" -d {dbname}"
    _, out, _ = run(q)
    try:
        return int(out.strip())
    except Exception:
        return 0


def service_cmd(cmd: str):
    """Execute systemd service command"""
    return run(f"systemctl {cmd} {ODOO_SERVICE}", check=False)[1]


def odoo_cli(dbname: str, args: str):
    """Execute Odoo CLI command"""
    return run(
        f'su -s /bin/bash {ODOO_USER} -c "{shlex.quote(ODOO_VENV)}/bin/python {shlex.quote(ODOO_BIN)} -d {shlex.quote(dbname)} {args}"'
    )


def alert(message: str):
    """Send alert via configured channels"""
    if SLACK_WEBHOOK_URL:
        try:
            import requests
            requests.post(SLACK_WEBHOOK_URL, json={"text": message}, timeout=5)
        except Exception as e:
            app.logger.error(f"Slack alert failed: {e}")
            
    if SMTP_HOST and ALERT_EMAIL_TO:
        try:
            msg = MIMEText(message)
            msg["Subject"] = "Odoo SaaS Alert"
            msg["From"] = ALERT_EMAIL_FROM
            msg["To"] = ALERT_EMAIL_TO
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as s:
                s.starttls()
                if SMTP_USER:
                    s.login(SMTP_USER, SMTP_PASS)
                s.sendmail(ALERT_EMAIL_FROM, [ALERT_EMAIL_TO], msg.as_string())
        except Exception as e:
            app.logger.error(f"Email alert failed: {e}")


def job_backup_tenant(dbname: str, local_tmp: str, s3_bucket: str, s3_key: str):
    """Background job: backup tenant to S3"""
    run(f"pg_dump -Fc {shlex.quote(dbname)} -f {shlex.quote(local_tmp)}")
    extra = {"ServerSideEncryption": S3_SSE} if S3_SSE else {}
    if S3_SSE == "aws:kms" and S3_KMS_KEY_ID:
        extra["SSEKMSKeyId"] = S3_KMS_KEY_ID
    s3.upload_file(local_tmp, s3_bucket, s3_key, ExtraArgs=extra)
    os.remove(local_tmp)
    return {"bucket": s3_bucket, "key": s3_key}


def ensure_lifecycle(bucket: str, prefix: str, days: int):
    """Ensure S3 lifecycle policy exists"""
    try:
        rules = s3.get_bucket_lifecycle_configuration(Bucket=bucket).get("Rules", [])
    except Exception:
        rules = []
    rule_id = f"expire-{prefix.replace('/', '-')}-{days}d"
    rule = {
        "ID": rule_id,
        "Filter": {"Prefix": f"{prefix}/"},
        "Status": "Enabled",
        "Expiration": {"Days": days},
    }
    existing = [r for r in rules if r.get("ID") == rule_id]
    if existing:
        for i, r in enumerate(rules):
            if r.get("ID") == rule_id:
                rules[i] = rule
    else:
        rules.append(rule)
    s3.put_bucket_lifecycle_configuration(
        Bucket=bucket, LifecycleConfiguration={"Rules": rules}
    )


def job_restore_tenant(dbname: str, s3_bucket: str, s3_key: str):
    """Background job: restore tenant from S3"""
    tmp = f"/tmp/{secrets.token_hex(8)}.dump"
    s3.download_file(s3_bucket, s3_key, tmp)
    run(f"createdb -O {ODOO_USER} {shlex.quote(dbname)}", check=False)
    run(f"pg_restore -c -d {shlex.quote(dbname)} {shlex.quote(tmp)}")
    os.remove(tmp)
    return True


def job_modules(dbname: str, install=None, upgrade=None):
    """Background job: install/upgrade modules"""
    cmds = []
    if install:
        mods = ",".join(install)
        cmds.append(f"-i {mods} --without-demo=all --stop-after-init")
    if upgrade:
        mods = ",".join(upgrade)
        cmds.append(f"-u {mods} --stop-after-init")
    for c in cmds:
        odoo_cli(dbname, c)
    return True


@login_mgr.user_loader
def load_user(uid):
    return User.query.get(int(uid))


@login_mgr.unauthorized_handler
def unauth():
    return redirect(url_for("login"))


with app.app_context():
    db.create_all()
    if User.query.count() == 0:
        pw = bcrypt.hashpw(BOOTSTRAP_PASSWORD.encode(), bcrypt.gensalt())
        db.session.add(User(email=BOOTSTRAP_EMAIL, pw_hash=pw, role=Role.OWNER))
        db.session.commit()


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        pwd = request.form.get("password", "")
        u = User.query.filter_by(email=email).first()
        if u and bcrypt.checkpw(pwd.encode(), u.pw_hash):
            login_user(u)
            return redirect(url_for("index"))
        flash("Invalid credentials", "error")
    return render_template_string(TPL_LOGIN)


@app.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("login"))


@app.route("/")
@login_required
@require_perm("view_dashboard")
def index():
    dbs = get_databases()
    metas = {
        m.dbname: m for m in TenantMeta.query.filter(TenantMeta.dbname.in_(dbs)).all()
    }
    rows = []
    for d in dbs:
        size_b = db_size_bytes(d)
        users = active_user_count(d)
        meta = metas.get(d)
        suspended = bool(meta.suspended) if meta else False
        quota_gb = meta.quota_gb if meta else 5
        over_quota = (size_b / 1024 / 1024 / 1024) > quota_gb
        if over_quota:
            alert(f"Tenant {d} over quota: size {size_b} bytes > {quota_gb} GB")
        rows.append(
            {
                "db": d,
                "url": f"http://{d}.{BASE_DOMAIN}",
                "size_b": size_b,
                "users": users,
                "suspended": suspended,
                "quota_gb": quota_gb,
                "over_quota": over_quota,
            }
        )
    status = service_cmd("status")
    return render_template_string(
        TPL_INDEX,
        rows=rows,
        base_domain=BASE_DOMAIN,
        csrf_token=csrf.dumps("ok"),
        status=status,
    )


@app.route("/users")
@login_required
@require_perm("manage_users")
def users_list():
    users = User.query.order_by(User.created_at.desc()).all()
    return render_template_string(TPL_USERS, users=users, csrf_token=csrf.dumps("ok"))


@app.route("/users/create", methods=["POST"])
@login_required
@require_perm("manage_users")
def users_create():
    csrf.loads(request.form.get("_csrf", ""))
    email = request.form["email"].strip().lower()
    role = request.form["role"]
    pwd = request.form["password"]
    if role not in (Role.OWNER, Role.ADMIN, Role.VIEWER):
        abort(400)
    if User.query.filter_by(email=email).first():
        flash("Email already exists", "error")
        return redirect(url_for("users_list"))
    pw = bcrypt.hashpw(pwd.encode(), bcrypt.gensalt())
    db.session.add(User(email=email, pw_hash=pw, role=role))
    db.session.commit()
    record("user.create", email, {"role": role})
    flash("User created", "ok")
    return redirect(url_for("users_list"))


@app.route("/users/delete", methods=["POST"])
@login_required
@require_perm("manage_users")
def users_delete():
    csrf.loads(request.form.get("_csrf", ""))
    uid = int(request.form["uid"])
    if uid == current_user.id:
        flash("Cannot delete yourself", "error")
        return redirect(url_for("users_list"))
    u = User.query.get(uid)
    if not u:
        abort(404)
    db.session.delete(u)
    db.session.commit()
    record("user.delete", u.email)
    flash("User deleted", "ok")
    return redirect(url_for("users_list"))


@app.route("/audit")
@login_required
@require_perm("view_audit")
def audit():
    logs = AuditLog.query.order_by(AuditLog.at.desc()).limit(500).all()
    return render_template_string(TPL_AUDIT, logs=logs)


@app.route("/tenants/create", methods=["POST"])
@login_required
@require_perm("create_tenant")
def tenants_create():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form.get("dbname", "").strip()
    if not dbname.replace("_", "").replace("-", "").isalnum():
        flash("Database name must be alphanumeric (underscores and hyphens allowed).", "error")
        return redirect(url_for("index"))
    run(f"createdb -O {ODOO_USER} {dbname}")
    odoo_cli(dbname, "-i base --without-demo=all --stop-after-init --log-level=warn")
    if not TenantMeta.query.filter_by(dbname=dbname).first():
        db.session.add(TenantMeta(dbname=dbname))
        db.session.commit()
    record("tenant.create", dbname)
    flash(f"Tenant '{dbname}' created.", "ok")
    return redirect(url_for("index"))


@app.route("/tenants/delete", methods=["POST"])
@login_required
@require_perm("delete_tenant")
def tenants_delete():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form["dbname"]
    run(f"dropdb {dbname}")
    TenantMeta.query.filter_by(dbname=dbname).delete()
    db.session.commit()
    record("tenant.delete", dbname)
    flash(f"Tenant '{dbname}' deleted.", "ok")
    return redirect(url_for("index"))


@app.route("/tenants/suspend", methods=["POST"])
@login_required
@require_perm("suspend_tenant")
def tenants_suspend():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form["dbname"]
    action = request.form.get("action", "suspend")
    if action == "suspend":
        run(f'psql -tAc "ALTER DATABASE {dbname} WITH ALLOW_CONNECTIONS = false;"')
        m = TenantMeta.query.filter_by(dbname=dbname).first() or TenantMeta(
            dbname=dbname
        )
        m.suspended = True
        db.session.add(m)
        db.session.commit()
        alert(f"Tenant {dbname} suspended")
        record("tenant.suspend", dbname)
    else:
        run(f'psql -tAc "ALTER DATABASE {dbname} WITH ALLOW_CONNECTIONS = true;"')
        m = TenantMeta.query.filter_by(dbname=dbname).first()
        if m:
            m.suspended = False
            db.session.commit()
        record("tenant.unsuspend", dbname)
    return redirect(url_for("index"))


@app.route("/tenants/quota", methods=["POST"])
@login_required
@require_perm("set_quota")
def tenants_quota():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form["dbname"]
    quota_gb = int(request.form["quota_gb"])
    m = TenantMeta.query.filter_by(dbname=dbname).first() or TenantMeta(dbname=dbname)
    m.quota_gb = quota_gb
    db.session.add(m)
    db.session.commit()
    record("tenant.quota.set", dbname, {"quota_gb": quota_gb})
    flash("Quota updated", "ok")
    return redirect(url_for("index"))


@app.route("/tenants/backup", methods=["POST"])
@login_required
@require_perm("backup_tenant")
def tenants_backup():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form["dbname"]
    ts = datetime.utcnow().strftime("%Y/%m/%d/%H%M%S")
    key = f"{S3_PREFIX}/{dbname}/{ts}.dump"
    tmp = f"/tmp/{secrets.token_hex(8)}.dump"
    ensure_lifecycle(S3_BUCKET, f"{S3_PREFIX}/{dbname}", S3_LIFECYCLE_DAYS)
    job = q.enqueue(job_backup_tenant, dbname, tmp, S3_BUCKET, key)
    record(
        "tenant.backup.enqueue",
        dbname,
        {"job_id": job.get_id(), "s3": {"bucket": S3_BUCKET, "key": key}},
    )
    flash(f"Backup queued (job {job.get_id()})", "ok")
    return redirect(url_for("jobs"))


@app.route("/tenants/restore", methods=["POST"])
@login_required
@require_perm("restore_tenant")
def tenants_restore():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form["dbname"].strip()
    s3key = request.form["s3key"].strip()
    job = q.enqueue(job_restore_tenant, dbname, S3_BUCKET, s3key)
    record("tenant.restore.enqueue", dbname, {"job_id": job.get_id(), "s3key": s3key})
    flash(f"Restore queued (job {job.get_id()})", "ok")
    return redirect(url_for("jobs"))


@app.route("/modules", methods=["POST"])
@login_required
@require_perm("modules_manage")
def modules():
    csrf.loads(request.form.get("_csrf", ""))
    dbname = request.form["dbname"]
    install = [
        m.strip() for m in request.form.get("install", "").split(",") if m.strip()
    ]
    upgrade = [
        m.strip() for m in request.form.get("upgrade", "").split(",") if m.strip()
    ]
    job = q.enqueue(job_modules, dbname, install, upgrade)
    record(
        "modules.enqueue",
        dbname,
        {"install": install, "upgrade": upgrade, "job_id": job.get_id()},
    )
    flash(f"Module job queued (job {job.get_id()})", "ok")
    return redirect(url_for("jobs"))


@app.route("/jobs")
@login_required
def jobs():
    keys = [k.decode() for k in rconn.keys("rq:job:*")]
    jobs = []
    for k in keys:
        jid = k.split(":")[-1]
        data = rconn.hgetall(k)
        status = data.get(b"status", b"unknown").decode()
        jobs.append({"id": jid, "status": status})
    return render_template_string(TPL_JOBS, jobs=jobs)


@app.route("/jobs/<job_id>")
@login_required
def job_detail(job_id):
    from rq.job import Job

    try:
        job = Job.fetch(job_id, connection=rconn)
    except Exception:
        abort(404)
    info = {
        "id": job.id,
        "status": job.get_status(refresh=True),
        "created_at": job.created_at,
        "enqueued_at": job.enqueued_at,
        "started_at": getattr(job, "started_at", None),
        "ended_at": getattr(job, "ended_at", None),
        "result": job.result,
        "exc_info": job.exc_info,
        "description": job.description,
    }
    if info["status"] == "failed":
        alert(f"Job {job_id} failed: {info['exc_info']}")
    return render_template_string(TPL_JOB_DETAIL, job=info)


@app.route("/logs")
@login_required
@require_perm("view_logs")
def logs():
    try:
        with open(ODOO_LOG, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()[-1000:]
        content = "".join(lines)
    except Exception as e:
        content = f"Error reading log: {e}"
    return render_template_string(TPL_LOGS, logs=content)


@app.route("/service/<action>", methods=["POST"])
@login_required
@require_perm("service_control")
def service_action(action):
    csrf.loads(request.form.get("_csrf", ""))
    if action not in {"restart", "stop", "start"}:
        abort(400)
    out = service_cmd(action)
    record(f"service.{action}", meta={"out": out})
    flash(out or f"Service {action} issued", "ok")
    return redirect(url_for("index"))


@app.route("/webhooks/billing", methods=["POST"])
def billing_webhook():
    raw = request.get_data()
    ev = None

    if STRIPE_SIGNING_SECRET and "Stripe-Signature" in request.headers:
        sig = request.headers["Stripe-Signature"]
        try:
            ev = stripe.Webhook.construct_event(raw, sig, STRIPE_SIGNING_SECRET)
        except Exception:
            return ("bad signature", 400)
    elif PADDLE_PUBLIC_KEY and request.form:
        form = request.form.to_dict(flat=False)
        p_sig = (
            base64.b64decode(form.pop("p_signature")[0])
            if "p_signature" in form
            else b""
        )
        ordered = {}
        for k in sorted(form.keys()):
            ordered[k] = form[k][0]
        payload = json.dumps(
            ordered, separators=(",", ":"), ensure_ascii=False
        ).encode()
        key = RSA.importKey(PADDLE_PUBLIC_KEY)
        h = SHA1.new(payload)
        verifier = PKCS1_v1_5.new(key)
        if not verifier.verify(h, p_sig):
            return ("bad signature", 400)
        ev = ordered
    elif WEBHOOK_SECRET:
        if request.headers.get("X-Webhook-Secret") != WEBHOOK_SECRET:
            return ("forbidden", 403)
        ev = request.get_json(force=True, silent=True)
    else:
        return ("forbidden", 403)

    etype = (ev.get("type") if isinstance(ev, dict) else ev["type"]) if ev else ""
    dbname = (
        (
            ev.get("tenant")
            if isinstance(ev, dict)
            else ev["data"]["object"].get("metadata", {}).get("tenant")
        )
        if ev
        else ""
    )
    record("webhook", dbname or "unknown", ev if isinstance(ev, dict) else {})
    if not dbname:
        return ("ok", 200)

    if etype in {"subscription.paused", "payment.failed", "subscription.canceled"}:
        run(f'psql -tAc "ALTER DATABASE {dbname} WITH ALLOW_CONNECTIONS = false;"')
        m = TenantMeta.query.filter_by(dbname=dbname).first() or TenantMeta(
            dbname=dbname
        )
        m.suspended = True
        db.session.add(m)
        db.session.commit()
        alert(f"Tenant {dbname} auto-suspended due to {etype}")
    elif etype in {"invoice.paid", "subscription.resumed"}:
        run(f'psql -tAc "ALTER DATABASE {dbname} WITH ALLOW_CONNECTIONS = true;"')
        m = TenantMeta.query.filter_by(dbname=dbname).first() or TenantMeta(
            dbname=dbname
        )
        m.suspended = False
        db.session.add(m)
        db.session.commit()
        alert(f"Tenant {dbname} unsuspended due to {etype}")
    return ("ok", 200)


@app.route("/health")
def health():
    """Health check endpoint"""
    return {"status": "healthy"}, 200


# ---- Templates ----
TPL_BASE = """
<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Odoo SaaS Admin</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bulma@0.9.4/css/bulma.min.css">
</head><body><section class="section"><div class="container">
<nav class="level">
  <div class="level-left"><h1 class="title">Odoo SaaS Admin</h1></div>
  <div class="level-right">
    <a class="button is-light" href="{{ url_for('index') }}">Dashboard</a>
    <a class="button is-light" href="{{ url_for('jobs') }}">Jobs</a>
    <a class="button is-light" href="{{ url_for('audit') }}">Audit</a>
    {% if current_user.is_authenticated and current_user.role=='OWNER' %}
      <a class="button is-info" href="{{ url_for('users_list') }}">Users</a>
    {% endif %}
    <a class="button is-light" href="{{ url_for('logout') }}">Logout</a>
  </div>
</nav>
{% with messages = get_flashed_messages(with_categories=true) %}
  {% if messages %}
    {% for cat,msg in messages %}
      <div class="notification is-{{ 'danger' if cat=='error' else 'primary' }}">{{ msg }}</div>
    {% endfor %}
  {% endif %}
{% endwith %}
{% block content %}{% endblock %}
</div></section></body></html>
"""

TPL_LOGIN = """
<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bulma@0.9.4/css/bulma.min.css"><title>Login</title></head>
<body class="has-background-light"><section class="section"><div class="container">
<div class="column is-half is-offset-one-quarter"><div class="box">
<h1 class="title">Admin Login</h1>
<form method="post">
  <div class="field"><label class="label">Email</label><input class="input" name="email" required></div>
  <div class="field"><label class="label">Password</label><input class="input" name="password" type="password" required></div>
  <div class="field"><button class="button is-primary is-fullwidth">Login</button></div>
</form>
</div></div>
</div></section></body></html>
"""

TPL_INDEX = """
{% extends TPL_BASE %}
{% block content %}
<div class="columns">
  <div class="column is-two-thirds">
    <h2 class="subtitle">Tenants</h2>
    <div class="box">
      <h3 class="subtitle">Create New Tenant</h3>
      <form method="post" action="{{ url_for('tenants_create') }}">
        <input type="hidden" name="_csrf" value="{{ csrf_token }}">
        <div class="field is-grouped">
          <div class="control is-expanded">
            <input class="input" name="dbname" placeholder="tenant_name" pattern="[a-z0-9_-]+" required>
          </div>
          <div class="control">
            <button class="button is-primary">Create</button>
          </div>
        </div>
      </form>
    </div>
    
    <table class="table is-striped is-fullwidth">
      <thead><tr><th>Database</th><th>URL</th><th>Users</th><th>Size (GB)</th><th>Quota (GB)</th><th>Status</th><th>Actions</th></tr></thead>
      <tbody>
        {% for r in rows %}
          <tr>
            <td><code>{{ r.db }}</code></td>
            <td><a href="http://{{ r.db }}.{{ base_domain }}" target="_blank">{{ r.db }}.{{ base_domain }}</a></td>
            <td>{{ r.users }}</td>
            <td>{{ '%.2f' % (r.size_b/1024/1024/1024) }}</td>
            <td>
              <form method="post" action="{{ url_for('tenants_quota') }}" class="is-inline">
                <input type="hidden" name="_csrf" value="{{ csrf_token }}">
                <input type="hidden" name="dbname" value="{{ r.db }}">
                <input class="input is-small" style="width:70px" name="quota_gb" value="{{ r.quota_gb }}">
                <button class="button is-small">Save</button>
              </form>
            </td>
            <td>
              {% if r.suspended %}<span class="tag is-danger">Suspended</span>{% else %}<span class="tag is-success">Active</span>{% endif %}
              {% if r.over_quota %}<span class="tag is-warning">Over quota</span>{% endif %}
            </td>
            <td>
              <form style="display:inline" method="post" action="{{ url_for('tenants_backup') }}">
                <input type="hidden" name="_csrf" value="{{ csrf_token }}">
                <input type="hidden" name="dbname" value="{{ r.db }}">
                <button class="button is-small">Backup</button>
              </form>
              <form style="display:inline" method="post" action="{{ url_for('tenants_suspend') }}">
                <input type="hidden" name="_csrf" value="{{ csrf_token }}">
                <input type="hidden" name="dbname" value="{{ r.db }}">
                {% if r.suspended %}
                  <input type="hidden" name="action" value="unsuspend">
                  <button class="button is-small is-success">Unsuspend</button>
                {% else %}
                  <input type="hidden" name="action" value="suspend">
                  <button class="button is-small is-warning">Suspend</button>
                {% endif %}
              </form>
              <form style="display:inline" method="post" action="{{ url_for('tenants_delete') }}" onsubmit="return confirm('Delete '+ '{{ r.db }}' + '?')">
                <input type="hidden" name="_csrf" value="{{ csrf_token }}">
                <input type="hidden" name="dbname" value="{{ r.db }}">
                <button class="button is-small is-danger">Delete</button>
              </form>
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>

    <div class="box">
      <h3 class="subtitle">Restore from S3</h3>
      <form method="post" action="{{ url_for('tenants_restore') }}">
        <input type="hidden" name="_csrf" value="{{ csrf_token }}">
        <div class="field is-grouped">
          <div class="control is-expanded"><input class="input" name="dbname" placeholder="tenant_db" required></div>
        </div>
        <div class="field"><label class="label">S3 key</label><input class="input" name="s3key" placeholder="{{ 'tenants/<db>/YYYY/MM/DD/HHMMSS.dump' }}" required></div>
        <button class="button is-link">Restore (queued)</button>
      </form>
    </div>

    <div class="box">
      <h3 class="subtitle">Modules</h3>
      <form method="post" action="{{ url_for('modules') }}">
        <input type="hidden" name="_csrf" value="{{ csrf_token }}">
        <div class="field is-grouped">
          <div class="control is-expanded"><input class="input" name="dbname" placeholder="tenant_db" required></div>
        </div>
        <div class="field"><label class="label">Install (comma-separated)</label><input class="input" name="install" placeholder="sale,crm,website"></div>
        <div class="field"><label class="label">Upgrade (comma-separated)</label><input class="input" name="upgrade" placeholder="base,stock"></div>
        <button class="button is-primary">Queue</button>
      </form>
    </div>

  </div>

  <div class="column">
    <h2 class="subtitle">Service</h2>
    <pre style="white-space:pre-wrap">{{ status }}</pre>
    <form method="post" action="{{ url_for('service_action', action='restart') }}">
      <input type="hidden" name="_csrf" value="{{ csrf_token }}">
      <button class="button is-warning is-fullwidth">Restart Odoo</button>
    </form>
    <br>
    <a class="button is-light is-fullwidth" href="{{ url_for('logs') }}">View Logs</a>
  </div>
</div>
{% endblock %}
"""

TPL_USERS = """
{% extends TPL_BASE %}
{% block content %}
<h2 class="subtitle">Users</h2>
<table class="table is-fullwidth is-striped"><thead><tr><th>Email</th><th>Role</th><th>Created</th><th>Actions</th></tr></thead><tbody>
{% for u in users %}
<tr><td>{{ u.email }}</td><td>{{ u.role }}</td><td>{{ u.created_at }}</td><td>
  <form method="post" action="{{ url_for('users_delete') }}" onsubmit="return confirm('Delete user?')">
    <input type="hidden" name="_csrf" value="{{ csrf_token }}">
    <input type="hidden" name="uid" value="{{ u.id }}">
    <button class="button is-small is-danger">Delete</button>
  </form>
</td></tr>
{% endfor %}
</tbody></table>

<div class="box"><h3 class="subtitle">Create User</h3>
<form method="post" action="{{ url_for('users_create') }}">
  <input type="hidden" name="_csrf" value="{{ csrf_token }}">
  <div class="field"><label class="label">Email</label><input class="input" name="email" required></div>
  <div class="field"><label class="label">Password</label><input class="input" name="password" type="password" required></div>
  <div class="field"><label class="label">Role</label>
    <div class="select"><select name="role">
      <option>ADMIN</option><option>OWNER</option><option>VIEWER</option>
    </select></div>
  </div>
  <button class="button is-primary">Create</button>
</form></div>
{% endblock %}
"""

TPL_AUDIT = """
{% extends TPL_BASE %}
{% block content %}
<h2 class="subtitle">Audit Log (latest 500)</h2>
<table class="table is-fullwidth is-striped"><thead><tr><th>When</th><th>Actor</th><th>Action</th><th>Target</th><th>Meta</th></tr></thead><tbody>
{% for e in logs %}
<tr><td>{{ e.at }}</td><td>{{ e.actor }}</td><td>{{ e.action }}</td><td>{{ e.target }}</td><td><pre style="white-space:pre-wrap">{{ e.meta }}</pre></td></tr>
{% endfor %}
</tbody></table>
{% endblock %}
"""

TPL_LOGS = """
{% extends TPL_BASE %}
{% block content %}
<h2 class="subtitle">Odoo Logs (last 1000 lines)</h2>
<pre style="max-height:70vh; overflow:auto; white-space:pre-wrap">{{ logs }}</pre>
{% endblock %}
"""

TPL_JOBS = """
{% extends TPL_BASE %}
{% block content %}
<h2 class="subtitle">Background Jobs</h2>
<table class="table is-fullwidth is-striped"><thead><tr><th>Job ID</th><th>Status</th><th>Details</th></tr></thead><tbody>
{% for j in jobs %}<tr><td><code>{{ j.id }}</code></td><td>{{ j.status }}</td><td><a class="button is-small" href="{{ url_for('job_detail', job_id=j.id) }}">View</a></td></tr>{% endfor %}
</tbody></table>
<p class="content">Processed by <code>odoo-admin-worker@*</code>. Check <code>journalctl -u odoo-admin-worker@1 -f</code> etc. for logs.</p>
{% endblock %}
"""

TPL_JOB_DETAIL = """
{% extends TPL_BASE %}
{% block content %}
<h2 class="subtitle">Job {{ job.id }}</h2>
<table class="table is-fullwidth is-striped">
<tr><th>Status</th><td>{{ job.status }}</td></tr>
<tr><th>Created</th><td>{{ job.created_at }}</td></tr>
<tr><th>Enqueued</th><td>{{ job.enqueued_at }}</td></tr>
<tr><th>Started</th><td>{{ job.started_at }}</td></tr>
<tr><th>Ended</th><td>{{ job.ended_at }}</td></tr>
<tr><th>Result</th><td><pre style="white-space:pre-wrap">{{ job.result }}</pre></td></tr>
<tr><th>Exception</th><td><pre style="white-space:pre-wrap">{{ job.exc_info }}</pre></td></tr>
<tr><th>Description</th><td>{{ job.description }}</td></tr>
</table>
{% endblock %}
"""

# bind base template name for extends to work with render_template_string
app.jinja_env.globals["TPL_BASE"] = TPL_BASE

if __name__ == "__main__":
    # Detect if running in Docker
    host = "0.0.0.0" if os.environ.get("DOCKER_ENV") else "127.0.0.1"
    app.run(host=host, port=PORT, debug=False)