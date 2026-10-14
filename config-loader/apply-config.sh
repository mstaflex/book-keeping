#!/bin/sh
# =============================================================================
# config-loader/apply-config.sh
#
# Schreibt Konfiguration aus Umgebungsvariablen in die Tabelle app_config.
# Läuft bei jedem Start des Containers (docker compose up, restart und nach
# einem Server-Neustart) und bleibt danach im Leerlauf.
#
# Namensschema  <SCOPE>_<KEY>  →  (scope, key) in Kleinbuchstaben:
#   ETSY_API_KEY        → ('etsy',    'api_key')
#   ETSY_RC_START_DATE  → ('etsy_rc', 'start_date')
#   SELLER_VAT_ID       → ('seller',  'vat_id')
#   LEXOFFICE_START_MONTH → ('lexoffice', 'start_month')
# Berücksichtigt werden nur die Präfixe ETSY_RC_, ETSY_, NOTION_, MAIL_,
# SELLER_ und LEXOFFICE_ – und nur Variablen, die docker-compose.yml an den Container
# durchreicht. Leere Variablen werden übersprungen, der Wert in der Datenbank
# bleibt dann unverändert.
#
# Werte werden nie geloggt (API-Keys!), nur die Schlüssel.
# =============================================================================
set -eu

log() { echo "[config] $*"; }

SECRETS=/run/secrets
PGHOST="${PGHOST:-orderdb}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="$(cat "$SECRETS/db_name.txt")"
PGUSER="$(cat "$SECRETS/db_worker_user.txt")"
PGPASSWORD="$(cat "$SECRETS/db_worker_password.txt")"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

# Nach einem Server-Neustart startet Docker die Container ohne depends_on-
# Reihenfolge – daher selbst warten, bis die Datenbank Verbindungen annimmt.
until pg_isready -q; do
  log "warte auf Datenbank ${PGHOST}:${PGPORT} ..."
  sleep 3
done

if [ "$(psql -X -At -c "SELECT to_regclass('public.app_config') IS NOT NULL")" != "t" ]; then
  log "FEHLER: Tabelle app_config fehlt – Migrationen ausführen (README: Updates einspielen)"
  exit 1
fi

# Werte als psql-Variablen übergeben: :'name' quotet sie sicher als SQL-
# Literal, auch mit Apostroph, Backslash oder Zeilenumbruch.
set --
sql=""
n=0
for name in $(env | grep -E -o '^(ETSY_RC|ETSY|NOTION|MAIL|SELLER|LEXOFFICE)_[A-Z0-9_]+=' | tr -d '=' | sort -u); do
  value="$(printenv "$name" || true)"
  [ -n "$value" ] || continue
  case "$name" in
    ETSY_RC_*) scope=etsy_rc; key=${name#ETSY_RC_} ;;
    ETSY_*)    scope=etsy;    key=${name#ETSY_} ;;
    NOTION_*)  scope=notion;  key=${name#NOTION_} ;;
    MAIL_*)    scope=mail;    key=${name#MAIL_} ;;
    SELLER_*)  scope=seller;  key=${name#SELLER_} ;;
    LEXOFFICE_*) scope=lexoffice; key=${name#LEXOFFICE_} ;;
  esac
  key=$(printf '%s' "$key" | tr 'A-Z' 'a-z')
  n=$((n + 1))
  set -- "$@" -v "s$n=$scope" -v "k$n=$key" -v "v$n=$value"
  sql="$sql
INSERT INTO app_config (scope, key, value) VALUES (:'s$n', :'k$n', :'v$n')
ON CONFLICT (scope, key) DO UPDATE SET value = EXCLUDED.value
WHERE app_config.value IS DISTINCT FROM EXCLUDED.value
RETURNING scope || '.' || key;"
done

if [ "$n" -eq 0 ]; then
  log "keine Konfigurations-Variablen gesetzt – app_config unverändert"
else
  changed=$(printf '%s\n' "$sql" | psql -X -q -At -v ON_ERROR_STOP=1 -1 "$@" -f - | tr '\n' ' ')
  log "$n Werte aus der Umgebung übernommen, davon geändert: ${changed:-keine}"
fi

# Hinweis, welche Pflichtwerte noch fehlen (die Workflows brechen sonst mit
# einer Fehlermeldung ab) – unabhängig davon, ob sie per Env oder SQL kamen.
missing() {
  psql -X -At -c "SELECT string_agg(k, ', ' ORDER BY k)
                  FROM unnest(string_to_array('$1', ' ')) AS k
                  WHERE NOT EXISTS (SELECT 1 FROM app_config c WHERE c.scope || '.' || c.key = k)"
}
m=$(missing 'etsy.api_key etsy.shop_id notion.database_id mail.from mail.to seller.name seller.street seller.zip seller.city')
[ -z "$m" ] || log "fehlt noch: $m"
m=$(missing 'seller.vat_id etsy_rc.recipient_name etsy_rc.recipient_street etsy_rc.recipient_city etsy_rc.recipient_country etsy_rc.recipient_vat_id etsy_rc.start_date')
[ -z "$m" ] || log "fehlt noch für Workflow 05 (Reverse Charge): $m"
m=$(missing 'lexoffice.start_month')
[ -z "$m" ] || log "fehlt noch für Workflow 06 (Lexoffice-Export): $m"

log "fertig – Leerlauf bis zum nächsten Start"
exec sleep 2147483647
