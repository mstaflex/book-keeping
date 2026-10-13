#!/bin/bash
# =============================================================================
# backup.sh – PostgreSQL-Dump erzeugen.
# Als Cron auf dem VPS einrichten:
#   0 3 * * * /opt/buschi-bookkeeping/backup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
CONTAINER="orderdb"   # container_name aus docker-compose.yml
KEEP_DAYS=30

mkdir -p "${BACKUP_DIR}"

# Die Secrets liegen im Docker-Volume secrets_data, nicht auf dem Host
# (./secrets gibt es nicht mehr) – daher aus dem laufenden Container lesen.
# "docker exec" statt "docker compose exec": funktioniert unabhängig davon,
# unter welchem Compose-Projektnamen/Verzeichnis der Stack deployt wurde.
DB_NAME=$(docker exec "${CONTAINER}" cat /run/secrets/db_name.txt)
ADMIN_USER=$(docker exec "${CONTAINER}" cat /run/secrets/db_admin_user.txt)
TIMESTAMP=$(date +%F_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"

# Bricht pg_dump ab, darf kein halbes Backup liegen bleiben, das wie ein
# gültiges aussieht (und die Rotation unten überlebt).
trap 'rm -f "${BACKUP_FILE}.partial"' EXIT

echo "[$(date)] Starte Backup → ${BACKUP_FILE}"

docker exec "${CONTAINER}" pg_dump -U "${ADMIN_USER}" "${DB_NAME}" \
    | gzip > "${BACKUP_FILE}.partial"
mv "${BACKUP_FILE}.partial" "${BACKUP_FILE}"

echo "[$(date)] Backup abgeschlossen ($(du -sh "${BACKUP_FILE}" | cut -f1))"

# Alte Backups löschen
find "${BACKUP_DIR}" -name "${DB_NAME}_*.sql.gz" -mtime "+${KEEP_DAYS}" -delete
echo "[$(date)] Backups älter als ${KEEP_DAYS} Tage bereinigt."
