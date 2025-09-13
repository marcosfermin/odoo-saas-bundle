FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_ENV=1 \
    ADMIN_DB_PATH=/opt/odoo-admin/admin.db

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates gcc pkg-config libpq-dev postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/odoo-admin && chmod 755 /opt/odoo-admin

# The admin_dashboard.py will be mounted as a volume at runtime
# So we don't COPY it during build

RUN pip install --no-cache-dir \
    flask itsdangerous python-dotenv flask_sqlalchemy flask_login bcrypt redis rq requests \
    boto3 stripe pycryptodome cryptography psycopg2-binary

EXPOSE 9090

# The application file will be mounted at /app/admin_dashboard.py
CMD ["python", "/app/admin_dashboard.py"]