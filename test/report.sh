#!/bin/bash
# =============================================================================
# test/report.sh – Prüfbericht (test/report.sql), nur lesend
#
#   test/report.sh          lokale Testumgebung (test/docker-compose.yml)
#   test/report.sh --prod   echte Datenbank (auf dem Server, Container orderdb)
#
# Im Repository-Root ausführen, während der jeweilige Stack läuft.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "")     exec_db() { docker compose -f test/docker-compose.yml exec -T orderdb "$@"; } ;;
  --prod) exec_db() { docker exec -i "${ORDERDB_CONTAINER:-orderdb}" "$@"; } ;;
  *)      sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

exec_db sh -c 'psql -X -q -v ON_ERROR_STOP=1 -P pager=off \
  -U "$(cat /run/secrets/db_admin_user.txt)" -d "$(cat /run/secrets/db_name.txt)" -f -' < test/report.sql
