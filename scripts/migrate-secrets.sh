#!/usr/bin/env bash
# Patrimonio — migration secrets checklist.
#
# When you move Patrimonio to a new box (e.g. a homelab), the Postgres
# dump is only half the story: the encrypted columns in it (Plaid access
# tokens, TOTP secrets, Coinbase tokens) ONLY decrypt with the same
# ENCRYPTION_KEY, and Plaid keeps working only if PLAID_* matches the
# environment the items were linked in. This script reads your current
# `.env` and prints exactly what to carry over — and what to CHANGE for
# the new hostname — so nothing is forgotten.
#
# It only prints to your terminal; it never writes a file. Copy the
# "carry verbatim" block into your password manager, then move on.
#
# Usage:
#   bash scripts/migrate-secrets.sh [path-to-.env]   # default ./.env
#
# Pairs with: docs/migration.md (the full runbook), scripts/backup.sh
# (the dump it travels with), and scripts/restore.sh (replay on the new box).

set -euo pipefail

ENV_FILE="${1:-.env}"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: no env file at '$ENV_FILE'." >&2
  echo "Pass the path explicitly: bash scripts/migrate-secrets.sh /path/to/.env" >&2
  exit 2
fi

# Read KEY from ENV_FILE, stripping surrounding quotes. Empty if absent.
getval() {
  local key="$1"
  # Last assignment wins; tolerate `export KEY=`, spaces, and quotes.
  local line
  line=$(grep -E "^(export[[:space:]]+)?${key}=" "$ENV_FILE" | tail -1 || true)
  [ -z "$line" ] && return 0
  local val="${line#*=}"
  # Strip one layer of matching single or double quotes.
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

show() {
  local key="$1"
  local val
  val=$(getval "$key")
  if [ -z "$val" ]; then
    printf '  %-24s (not set)\n' "$key"
  else
    printf '  %-24s %s\n' "$key" "$val"
  fi
}

echo "============================================================"
echo " Patrimonio migration secrets   (source: $ENV_FILE)"
echo "============================================================"
echo
echo "These are SECRETS printed in the clear on your terminal."
echo "Copy them into a password manager, then clear your scrollback."
echo
echo "── CARRY VERBATIM (must match on the new box, or data breaks) ──"
echo
echo "  # CRITICAL: without ENCRYPTION_KEY, every Plaid/TOTP/Coinbase"
echo "  # token in the dump is permanently unrecoverable."
show ENCRYPTION_KEY
echo
echo "  # Plaid: must match the environment the items were linked in."
show PLAID_CLIENT_ID
show PLAID_SECRET
show PLAID_ENV
echo
show COINBASE_CLIENT_ID
show COINBASE_CLIENT_SECRET
show EXCHANGE_RATE_API_KEY
echo
echo "  # Needed to DECRYPT the backup you're carrying (scripts/backup.sh)."
echo "  # Not stored in .env — printed here only as a reminder:"
printf '  %-24s %s\n' "BACKUP_PASSPHRASE" "(from your password manager)"
echo
echo "── CHANGE FOR THE NEW HOST (current values shown for reference) ──"
echo
echo "  # Point these at the new hostname; re-register the redirect/webhook"
echo "  # URLs in the Plaid and Coinbase dashboards."
show FRONTEND_BASE_URL
show ALLOWED_ORIGINS
show PLAID_WEBHOOK_URL
show PLAID_REDIRECT_URI
show COINBASE_REDIRECT_URI
echo
echo "  # Infra/connection — can be regenerated on the new box as long as"
echo "  # DATABASE_URL / REDIS_URL match what docker-compose creates."
show POSTGRES_PASSWORD
show REDIS_PASSWORD
show COOKIE_SECURE
show TRUSTED_PROXY_CIDRS
echo
echo "============================================================"
echo " Next: see docs/migration.md for the full step-by-step."
echo "============================================================"
