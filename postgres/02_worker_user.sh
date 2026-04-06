#!/bin/bash
# =============================================================================
# Legt den eingeschränkten n8n-Datenbankuser an.
# Läuft nur beim ersten Start (leeres Daten-Volume).
# =============================================================================
set -euo pipefail

WORKER_USER=$(cat /run/secrets/db_worker_user.txt)
WORKER_PASSWORD=$(cat /run/secrets/db_worker_password.txt)
DB_NAME=$(cat /run/secrets/db_name.txt)
ADMIN_USER=$(cat /run/secrets/db_admin_user.txt)

echo ">>> Erstelle Worker-User '${WORKER_USER}' für Datenbank '${DB_NAME}' ..."

psql -v ON_ERROR_STOP=1 \
     --username "${ADMIN_USER}" \
     --dbname   "${DB_NAME}" \
<<-EOSQL
    -- User anlegen
    CREATE USER ${WORKER_USER} WITH PASSWORD '${WORKER_PASSWORD}';

    -- Verbindung zur Datenbank erlauben
    GRANT CONNECT ON DATABASE ${DB_NAME} TO ${WORKER_USER};

    -- Schema-Nutzung erlauben
    GRANT USAGE ON SCHEMA public TO ${WORKER_USER};

    -- Lese- und Schreibrechte auf alle bestehenden Tabellen
    GRANT SELECT, INSERT, UPDATE, DELETE
        ON ALL TABLES IN SCHEMA public
        TO ${WORKER_USER};

    -- Rechte auch auf zukünftige Tabellen (die admin anlegt)
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${WORKER_USER};

    -- Sequences (für SERIAL/BIGSERIAL-Spalten)
    GRANT USAGE, SELECT
        ON ALL SEQUENCES IN SCHEMA public
        TO ${WORKER_USER};

    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT USAGE, SELECT ON SEQUENCES TO ${WORKER_USER};
EOSQL

echo ">>> Worker-User '${WORKER_USER}' erfolgreich angelegt."
