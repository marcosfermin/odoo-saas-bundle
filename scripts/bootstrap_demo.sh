#!/usr/bin/env bash
set -euo pipefail

DBNAME="${1:-demo}"
ODOO_USER="${ODOO_USER:-odoo}"
ODOO_DIR="${ODOO_DIR:-/opt/${ODOO_USER}/odoo-16.0}"
ODOO_VENV="${ODOO_VENV:-/opt/${ODOO_USER}/venv}"

createdb -O "${ODOO_USER}" "${DBNAME}" || true
su -s /bin/bash "${ODOO_USER}" -c "${ODOO_VENV}/bin/python ${ODOO_DIR}/odoo-bin -d ${DBNAME} -i base,crm,sale,website --without-demo=all --stop-after-init --log-level=warn"
echo "Demo tenant '${DBNAME}' ready."
