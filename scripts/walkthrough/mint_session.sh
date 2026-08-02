#!/usr/bin/env bash
# =============================================================================
# DEV-ONLY TOOLING — writes a session row directly into the LOCAL dev Postgres
# (127.0.0.1:5442, db `patrimonio`). Never point this at prod: prod session
# minting is a human-approved, short-TTL, revoke-after procedure — not a script.
# =============================================================================
#
# Mints a `patrimonio_session` cookie for a user by inserting a row into
# user_sessions, exactly the way backend/src/services/sessions.rs does it:
#   raw cookie value = url-safe base64 (no padding) of 32 random bytes
#   stored token     = sha256(raw) as BYTEA          (DB never sees the raw)
#   pending_totp     = false                          (else require_auth rejects)
#
# The cookie lets a headless browser (or curl) skip the Flutter login canvas:
# inject it into the Playwright context / send it as a Cookie header and the
# app's auth_gate boots straight into the dashboard.
#
# Usage:
#   scripts/walkthrough/mint_session.sh [username] [ttl]
#     username  default: claude_dev      (the data-rich local QA account)
#     ttl       default: "30 minutes"    (a Postgres interval, e.g. "2 hours")
#   env: PATRIMONIO_DB_URL overrides the connection string.
#
# stdout: the raw cookie value (and nothing else — safe to $(...) capture).
# stderr: session id, expiry, and the exact cleanup command.
#
# Clean up when done (walkthrough sessions should not linger, even in dev):
#   psql "$DB_URL" -c "DELETE FROM user_sessions WHERE id = '<session-id>'"

set -euo pipefail

USER_NAME="${1:-claude_dev}"
TTL="${2:-30 minutes}"
DB_URL="${PATRIMONIO_DB_URL:-postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio}"

# Both values are interpolated into SQL below — keep them boring.
if ! [[ "$USER_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
  echo "mint_session.sh: username '$USER_NAME' has characters I refuse to inline into SQL" >&2
  exit 1
fi
if ! [[ "$TTL" =~ ^[0-9]+[[:space:]]+(second|minute|hour|day)s?$ ]]; then
  echo "mint_session.sh: ttl must look like '30 minutes' / '2 hours', got '$TTL'" >&2
  exit 1
fi

# Same token recipe as sessions.rs::generate_token().
RAW="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
HASH="$(printf '%s' "$RAW" | sha256sum | cut -d' ' -f1)"

# head -n1 drops the trailing "INSERT 0 1" command tag psql emits even with -tA.
SESSION_ROW="$(psql "$DB_URL" -tA <<SQL | head -n1
INSERT INTO user_sessions (user_id, token_hash, expires_at, pending_totp, user_agent)
SELECT id, decode('$HASH', 'hex'), now() + interval '$TTL', false, 'walkthrough-rig mint_session.sh'
FROM users
WHERE LOWER(username) = LOWER('$USER_NAME') AND is_active
RETURNING id || '|' || expires_at;
SQL
)"

if [[ -z "$SESSION_ROW" ]]; then
  echo "mint_session.sh: no active user named '$USER_NAME' in $DB_URL" >&2
  exit 1
fi

SESSION_ID="${SESSION_ROW%%|*}"
EXPIRES_AT="${SESSION_ROW#*|}"

{
  echo "minted session $SESSION_ID for '$USER_NAME' (expires $EXPIRES_AT)"
  echo "use:     curl -H 'Cookie: patrimonio_session=<cookie>' -H 'X-Requested-With: rig' http://127.0.0.1:3300/api/..."
  echo "cleanup: psql \"$DB_URL\" -c \"DELETE FROM user_sessions WHERE id = '$SESSION_ID'\""
} >&2

echo "$RAW"
