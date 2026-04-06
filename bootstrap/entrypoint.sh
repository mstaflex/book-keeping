#!/bin/sh
# =============================================================================
# bootstrap/entrypoint.sh
#
# Writes secret files from env vars on first run.
# Files containing "PLACEHOLDER" (committed to git so bind-mounts resolve)
# are treated as uninitialized and will be overwritten.
# Files with real content are left untouched on subsequent runs.
#
# If an env var is missing, a sane default (for names) or a generated
# 20-char alphanumeric password is used.
# Generated/defaulted credentials are printed once to stdout.
# =============================================================================
set -e

SECRETS_DIR="/secrets"
GENERATED=""

gen_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
}

# ---------------------------------------------------------------------------
# write_secret NAME ENV_VALUE DEFAULT_VALUE IS_PASSWORD
#   Skips if file exists AND does not contain "PLACEHOLDER".
# ---------------------------------------------------------------------------
write_secret() {
    local name="$1"
    local env_val="$2"
    local default_val="$3"
    local is_password="$4"
    local path="${SECRETS_DIR}/${name}.txt"

    # Already initialised – leave it alone
    if [ -f "$path" ] && [ "$(cat "$path")" != "PLACEHOLDER" ]; then
        echo "[bootstrap] ${name}.txt already initialised – skipped."
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
    chmod 644 "$path"
    echo "[bootstrap] ${name}.txt written (source: ${source})."

    if [ "$source" != "env" ]; then
        GENERATED="${GENERATED}
  ${name}: ${value}  [${source}]"
    fi
}

# ---------------------------------------------------------------------------
# Defaults:
#   DB_NAME            → orderdb
#   DB_ADMIN_USER      → root
#   DB_ADMIN_PASSWORD  → <generated>
#   DB_WORKER_USER     → buschi
#   DB_WORKER_PASSWORD → <generated>
# ---------------------------------------------------------------------------
write_secret "db_name"            "${DB_NAME:-}"            "orderdb"  "no"
write_secret "db_admin_user"      "${DB_ADMIN_USER:-}"      "root"     "no"
write_secret "db_admin_password"  "${DB_ADMIN_PASSWORD:-}"  ""         "yes"
write_secret "db_worker_user"     "${DB_WORKER_USER:-}"     "buschi"   "no"
write_secret "db_worker_password" "${DB_WORKER_PASSWORD:-}" ""         "yes"

# ---------------------------------------------------------------------------
# Print summary for anything that was auto-generated or defaulted
# ---------------------------------------------------------------------------
if [ -n "$GENERATED" ]; then
    echo ""
    echo "+-----------------------------------------------------------------+"
    echo "|  GENERATED / DEFAULT CREDENTIALS  (printed once only)          |"
    echo "|  Save these now – they will NOT be shown again.                 |"
    echo "+-----------------------------------------------------------------+"
    echo "$GENERATED" | while IFS= read -r line; do
        [ -n "$line" ] && printf "|  %-65s|\n" "$line"
    done
    echo "|                                                                 |"
    echo "|  n8n connection string:                                         |"
    printf "|  postgresql://%-50s|\n" \
        "$(cat "${SECRETS_DIR}/db_worker_user.txt"):$(cat "${SECRETS_DIR}/db_worker_password.txt")@127.0.0.1:5432/$(cat "${SECRETS_DIR}/db_name.txt")"
    echo "+-----------------------------------------------------------------+"
    echo ""
fi

echo "[bootstrap] Done."
