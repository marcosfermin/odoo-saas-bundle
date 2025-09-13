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
    jsonify,
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

# Optional imports with error handling
try:
    import stripe
except ImportError:
    stripe = None

try:
    from Crypto.PublicKey import RSA
    from Crypto.Hash import SHA1
    from Crypto.Signature import PKCS1_v1_5
except ImportError:
    RSA = None
    SHA1 = None
    PKCS1_v1_5 = None

load_dotenv()

APP_SECRET = os.environ.get("SECRET_KEY", secrets.token_hex(32))
PORT = int(os.environ.get("PORT", "9090"))
REDIS_URL = os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")

STRIPE_SIGNING_SECRET = os.environ.get("STRIPE_SIGNING_SECRET", "")
PADDLE_PUB_B64 = os.environ.get("PADDLE_PUBLIC_KEY_BASE64", "")

# Handle base64 decoding error
try:
    PADDLE_PUBLIC_KEY = base64.b64decode(PADDLE_PUB_B64).decode() if PADDLE_PUB_B64 else ""
except Exception as e:
    print(f"Warning: Could not decode PADDLE_PUBLIC_KEY_BASE64: {e}")
    PADDLE_PUBLIC_KEY = ""

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

# Database path configuration
DB_PATH = os.environ.get("ADMIN_DB_PATH", "/opt/odoo-admin/admin.db")
DB_DIR = os.path.dirname(DB_PATH)

app = Flask(__name__)
app.secret_key = APP_SECRET

# Ensure database directory exists
if not os.path.exists(DB_DIR):
    os.makedirs(DB_DIR, exist_ok=True)

app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{DB_PATH}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

# Initialize Flask extensions
db = SQLAlchemy(app)
login_mgr = LoginManager(app)

# Initialize Redis and RQ with error handling
try:
    rconn = redis.from_url(REDIS_URL)
    q = Queue("odoo_admin_jobs", connection=rconn)
except Exception as e:
    print(f"Warning: Could not connect to Redis: {e}")
    rconn = None
    q = None

# Initialize S3 client with error handling
try:
    if os.environ.get("AWS_ACCESS_KEY_ID"):
        s3 = boto3.client("s3", region_name=AWS_REGION)
    else:
        s3 = boto3.client("s3", region_name=AWS_REGION)
except Exception as e:
    print(f"Warning: Could not initialize S3 client: {e}")
    s3 = None

# Simple models for initial setup
class User(db.Model, UserMixin):
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(200), unique=True, nullable=False)
    pw_hash = db.Column(db.LargeBinary, nullable=False)
    role = db.Column(db.String(10), nullable=False, default="ADMIN")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

@login_mgr.user_loader
def load_user(uid):
    return User.query.get(int(uid))

@login_mgr.unauthorized_handler
def unauth():
    return redirect(url_for("login"))

# Create tables
with app.app_context():
    db.create_all()
    # Create bootstrap user if no users exist
    if User.query.count() == 0:
        pw = bcrypt.hashpw(BOOTSTRAP_PASSWORD.encode(), bcrypt.gensalt())
        db.session.add(User(email=BOOTSTRAP_EMAIL, pw_hash=pw, role="OWNER"))
        db.session.commit()
        print(f"Created bootstrap user: {BOOTSTRAP_EMAIL}")

@app.route("/")
def index():
    """Main dashboard page"""
    return render_template_string("""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Odoo SaaS Admin Dashboard</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
            h1 { color: #333; }
            .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
            .status { padding: 20px; background: #e8f5e9; border-radius: 5px; margin: 20px 0; }
            .ok { color: #2e7d32; font-weight: bold; }
            .warning { color: #f57c00; }
            .info { background: #f0f0f0; padding: 15px; border-radius: 5px; margin: 20px 0; }
            a { color: #1976d2; text-decoration: none; }
            a:hover { text-decoration: underline; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🚀 Odoo SaaS Admin Dashboard</h1>
            <div class="status">
                <p class="ok">✓ Admin Dashboard is running successfully!</p>
            </div>
            
            <div class="info">
                <h2>System Status</h2>
                <ul>
                    <li>Port: {{ port }}</li>
                    <li>Environment: Docker</li>
                    <li>Redis: {{ redis_status }}</li>
                    <li>S3: {{ s3_status }}</li>
                </ul>
            </div>
            
            <div class="info">
                <h2>Quick Actions</h2>
                <ul>
                    <li><a href="/login">Login to Admin Panel</a></li>
                    <li><a href="/health">Health Check API</a></li>
                    <li><a href="http://localhost">Access Odoo (port 80)</a></li>
                </ul>
            </div>
            
            <div class="info">
                <h2>Configuration Status</h2>
                <p class="warning">⚠️ Some services are not configured:</p>
                <ul>
                    <li>Stripe: {{ 'Configured' if stripe_configured else 'Not configured' }}</li>
                    <li>Paddle: {{ 'Configured' if paddle_configured else 'Not configured' }}</li>
                    <li>S3 Backups: {{ 'Configured' if s3_configured else 'Not configured' }}</li>
                    <li>Email Alerts: {{ 'Configured' if smtp_configured else 'Not configured' }}</li>
                </ul>
                <p><small>Edit your .env file to configure these services</small></p>
            </div>
        </div>
    </body>
    </html>
    """, 
        port=PORT,
        redis_status="Connected" if rconn else "Not connected",
        s3_status="Configured" if s3 else "Not configured",
        stripe_configured=bool(STRIPE_SIGNING_SECRET),
        paddle_configured=bool(PADDLE_PUBLIC_KEY),
        s3_configured=bool(S3_BUCKET),
        smtp_configured=bool(SMTP_HOST)
    )

@app.route("/health")
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "service": "admin-dashboard",
        "port": PORT,
        "redis": "connected" if rconn else "disconnected",
        "timestamp": datetime.utcnow().isoformat()
    }), 200

@app.route("/login", methods=["GET", "POST"])
def login():
    """Login page"""
    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        pwd = request.form.get("password", "")
        u = User.query.filter_by(email=email).first()
        if u and bcrypt.checkpw(pwd.encode(), u.pw_hash):
            login_user(u)
            return redirect(url_for("index"))
        flash("Invalid credentials", "error")
    
    return render_template_string("""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Admin Login</title>
        <style>
            body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
            .login-box { background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); width: 350px; }
            h2 { margin-top: 0; color: #333; text-align: center; }
            input { width: 100%; padding: 10px; margin: 10px 0; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; }
            button { width: 100%; padding: 12px; background: #1976d2; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; }
            button:hover { background: #1565c0; }
            .error { color: #f44336; text-align: center; margin: 10px 0; }
            .info { color: #666; font-size: 12px; text-align: center; margin-top: 20px; }
        </style>
    </head>
    <body>
        <div class="login-box">
            <h2>🔐 Admin Login</h2>
            {% with messages = get_flashed_messages(with_categories=true) %}
                {% if messages %}
                    {% for cat, msg in messages %}
                        <div class="error">{{ msg }}</div>
                    {% endfor %}
                {% endif %}
            {% endwith %}
            <form method="post">
                <input type="email" name="email" placeholder="Email" required value="{{ bootstrap_email }}">
                <input type="password" name="password" placeholder="Password" required>
                <button type="submit">Login</button>
            </form>
            <div class="info">
                <p>Default credentials:</p>
                <p>Email: {{ bootstrap_email }}</p>
                <p>Password: (from BOOTSTRAP_PASSWORD in .env)</p>
            </div>
        </div>
    </body>
    </html>
    """, bootstrap_email=BOOTSTRAP_EMAIL)

@app.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("login"))

if __name__ == "__main__":
    # Detect if running in Docker
    host = "0.0.0.0" if os.environ.get("DOCKER_ENV") else "127.0.0.1"
    
    print(f"Starting Odoo SaaS Admin Dashboard...")
    print(f"Host: {host}")
    print(f"Port: {PORT}")
    print(f"Database: {DB_PATH}")
    print(f"Redis: {'Connected' if rconn else 'Not connected'}")
    print(f"S3: {'Configured' if s3 else 'Not configured'}")
    
    app.run(host=host, port=PORT, debug=False)
