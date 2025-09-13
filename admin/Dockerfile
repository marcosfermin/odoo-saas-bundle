FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_ENV=1 \
    ADMIN_DB_PATH=/opt/odoo-admin/admin.db

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates gcc pkg-config libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Create directory for database
RUN mkdir -p /opt/odoo-admin && chmod 755 /opt/odoo-admin

COPY admin_dashboard.py /app/admin_dashboard.py

RUN pip install --no-cache-dir \
    flask itsdangerous python-dotenv flask_sqlalchemy flask_login bcrypt redis rq requests \
    boto3 stripe==9.* pycryptodome cryptography

EXPOSE 9090

# Run as non-root user in production
RUN useradd -m -u 1001 appuser && chown -R appuser:appuser /app /opt/odoo-admin
USER appuser

CMD ["python", "/app/admin_dashboard.py"]