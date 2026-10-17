#!/bin/sh
# =============================================================================
# Spielt bei jedem Deploy alle Migrationen aus /opt/migrations ein
# (Service "migrate" in docker-compose.yml, läuft vor dem Config-Loader).
# Die Migrationen sind idempotent: bereits angewendete ändern nichts.
# Beim allerersten Start mit leerem Volume laufen sie zusätzlich schon in
# initdb (03_migrations.sh); ein zweiter Lauf schadet nicht.
# =============================================================================
set -eu

PGHOST="${PGHOST:-orderdb}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="$(cat /run/secrets/db_name.txt)"
PGUSER="$(cat /run/secrets/db_admin_user.txt)"
PGPASSWORD="$(cat /run/secrets/db_admin_password.txt)"
# NOTICE-Meldungen ("already exists, skipping") ausblenden, Fehler bleiben sichtbar
PGOPTIONS="-c client_min_messages=warning"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGOPTIONS

until pg_isready -q; do
  echo "[migrate] warte auf Datenbank ${PGHOST}:${PGPORT} ..."
  sleep 2
done

for f in /opt/migrations/*.sql; do
  echo "[migrate] $(basename "$f")"
  psql -X -q -v ON_ERROR_STOP=1 -f "$f"
done
echo "[migrate] alle Migrationen angewendet"
