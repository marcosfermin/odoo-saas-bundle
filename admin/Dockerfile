FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates gcc pkg-config libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY admin_dashboard.py /app/admin_dashboard.py

RUN pip install --no-cache-dir \
    flask itsdangerous python-dotenv flask_sqlalchemy flask_login bcrypt redis rq requests \
    boto3 stripe==9.* pycryptodome cryptography

EXPOSE 9090
CMD ["python", "/app/admin_dashboard.py"]
