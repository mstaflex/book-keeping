#!/bin/bash
# =============================================================================
# Führt beim allerersten Start (leeres Daten-Volume) nach dem Schema auch alle
# Migrationen aus. Views und Funktionen (z.B. der Lexoffice-Export aus 004)
# stehen nur dort, und eine Neuinstallation soll exakt den Stand einer
# aktualisierten Installation haben. Die Migrationen sind idempotent.
# Läuft nach 02_worker_user.sh, damit dessen Default-Rechte auch für die hier
# angelegten Tabellen gelten.
# =============================================================================
set -euo pipefail

DB_NAME=$(cat /run/secrets/db_name.txt)
ADMIN_USER=$(cat /run/secrets/db_admin_user.txt)

for f in /opt/migrations/*.sql; do
    echo ">>> Migration $(basename "$f") ..."
    psql -v ON_ERROR_STOP=1 --username "${ADMIN_USER}" --dbname "${DB_NAME}" -f "$f"
done
