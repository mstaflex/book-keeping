#!/bin/bash
# =============================================================================
# postgres/tests/run.sh – Tests der Datenbanklogik (Lexoffice-Export)
#
# Spielt Schema, alle Migrationen und die Tests in eine WEGWERF-Datenbank ein:
#
#   postgres/tests/run.sh
#       startet einen temporären Container postgres:16-alpine (wie im Stack),
#       ohne Netzwerk und ohne Volumes, und entfernt ihn danach wieder
#
#   PGHOST=... PGPORT=... PGUSER=... postgres/tests/run.sh --server
#       legt auf einem vorhandenen Test-Server eine neue Datenbank an und
#       löscht sie danach; vorhandene Datenbanken werden nicht angefasst
#
# Nie gegen die echte Datenbank richten: die Tests schreiben Testdaten.
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILES=("$DIR/01_schema.sql" "$DIR"/migrations/*.sql "$DIR/tests/lexoffice_export_test.sql")

if [ "${1:-}" = "--server" ]; then
  DB="bookkeeping_test_$$"
  createdb "$DB"
  trap 'dropdb --if-exists "$DB"' EXIT
  for f in "${FILES[@]}"; do
    echo ">>> $(basename "$f")"
    psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
  done
  exit 0
fi

NAME="bookkeeping-test-$$"
docker run -d --rm --name "$NAME" --network none \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test postgres:16-alpine >/dev/null
trap 'docker stop "$NAME" >/dev/null' EXIT
# Das Image startet beim ersten Mal kurz neu; erst danach ist es bereit
for _ in $(seq 1 30); do
  docker exec "$NAME" pg_isready -q -U postgres -d test -h 127.0.0.1 && break
  sleep 1
done
for f in "${FILES[@]}"; do
  echo ">>> $(basename "$f")"
  docker exec -i "$NAME" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d test < "$f"
done
