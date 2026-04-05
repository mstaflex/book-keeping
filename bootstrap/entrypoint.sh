#!/bin/sh
# =============================================================================
# bootstrap/entrypoint.sh
#
# Writes secret files from env vars on first run.
# If an env var is missing, a sane default (name) or a generated password
# is used instead. Generated credentials are printed once to stdout so they
# show up in "docker compose logs bootstrap".
#
# On subsequent runs the existing *.txt files are kept as-is.
# =============================================================================
set -e

SECRETS_DIR="/secrets"
GENERATED=""   # collects lines for the summary block

gen_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
}

# ---------------------------------------------------------------------------
# write_or_default NAME ENV_VALUE DEFAULT_VALUE IS_PASSWORD
#   - Skips if file already exists
#   - Uses ENV_VALUE if non-empty
#   - Otherwise uses DEFAULT_VALUE (names) or generates a password
# ---------------------------------------------------------------------------
write_or_default() {
    local name="$1"
    local env_val="$2"
    local default_val="$3"
    local is_password="$4"   # "yes" → generate if empty; "no" → use default_val
    local path="${SECRETS_DIR}/${name}.txt"

    if [ -f "$path" ]; then
        echo "[bootstrap] ${name}.txt already exists – skipped."
        return
    fi

    local value=""
    local source=""

    if [ -n "$env_val" ]; then
        value="$env_val"
        source="env"
    elif [ "$is_password" = "yes" ]; then
        value="$(gen_password)"
        source="generated"
    else
        value="$default_val"
        source="default"
    fi

    printf '%s' "$value" > "$path"
    chmod 600 "$path"
    echo "[bootstrap] ${name}.txt written (source: ${source})."

    # Collect generated/defaulted values for summary
    if [ "$source" != "env" ]; then
        GENERATED="${GENERATED}
  ${name}: ${value}  [${source}]"
    fi
}

# ---------------------------------------------------------------------------
# Apply defaults
#   DB_NAME:            orderdb
#   DB_ADMIN_USER:      root
#   DB_ADMIN_PASSWORD:  <generated>
#   DB_WORKER_USER:     buschi
#   DB_WORKER_PASSWORD: <generated>
# ---------------------------------------------------------------------------
write_or_default "db_name"            "${DB_NAME:-}"            "orderdb"  "no"
write_or_default "db_admin_user"      "${DB_ADMIN_USER:-}"      "root"     "no"
write_or_default "db_admin_password"  "${DB_ADMIN_PASSWORD:-}"  ""         "yes"
write_or_default "db_worker_user"     "${DB_WORKER_USER:-}"     "buschi"   "no"
write_or_default "db_worker_password" "${DB_WORKER_PASSWORD:-}" ""         "yes"

# ---------------------------------------------------------------------------
# Print summary if anything was auto-generated or defaulted
# ---------------------------------------------------------------------------
if [ -n "$GENERATED" ]; then
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  GENERATED / DEFAULT CREDENTIALS  (printed once only)      │"
    echo "│  Save these now – they will NOT be shown again.             │"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "$GENERATED" | while IFS= read -r line; do
        [ -n "$line" ] && printf "│  %-60s│\n" "$line"
    done
    echo "│                                                             │"
    echo "│  n8n connection string:                                     │"
    printf "│  postgresql://%-45s│\n" \
        "$(cat ${SECRETS_DIR}/db_worker_user.txt):$(cat ${SECRETS_DIR}/db_worker_password.txt)@127.0.0.1:5432/$(cat ${SECRETS_DIR}/db_name.txt)"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
fi

echo "[bootstrap] Done."
