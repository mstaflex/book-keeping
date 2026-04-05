#!/bin/bash
# =============================================================================
# backup.sh – PostgreSQL-Dump erzeugen.
# Als Cron auf dem VPS einrichten:
#   0 3 * * * /opt/buschi-bookkeeping/backup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
SECRETS_DIR="${SCRIPT_DIR}/secrets"
KEEP_DAYS=30

mkdir -p "${BACKUP_DIR}"

DB_NAME=$(cat "${SECRETS_DIR}/db_name.txt")
ADMIN_USER=$(cat "${SECRETS_DIR}/db_admin_user.txt")
TIMESTAMP=$(date +%F_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"

echo "[$(date)] Starte Backup → ${BACKUP_FILE}"

docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T postgres \
    pg_dump -U "${ADMIN_USER}" "${DB_NAME}" \
    | gzip > "${BACKUP_FILE}"

echo "[$(date)] Backup abgeschlossen ($(du -sh "${BACKUP_FILE}" | cut -f1))"

# Alte Backups löschen
find "${BACKUP_DIR}" -name "${DB_NAME}_*.sql.gz" -mtime "+${KEEP_DAYS}" -delete
echo "[$(date)] Backups älter als ${KEEP_DAYS} Tage bereinigt."
