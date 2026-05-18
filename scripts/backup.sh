#!/usr/bin/env bash
# Patrimonio backup script — encrypted pg_dump.
#
# Why this exists: the entire app state — Plaid access tokens
# (encrypted at rest, but only with ENCRYPTION_KEY which lives in
# `.env`), TOTP secrets, passkey credentials, every transaction,
# every holding lot, every balance snapshot — sits on the
# `patrimonio_pgdata` Docker volume. One `docker volume prune --force`
# or one disk failure and the user starts over.
#
# The fix: pg_dump → GPG symmetric AES-256 → timestamped file in
# `$BACKUP_DIR`. The dump bytes never touch disk in plaintext.
#
# IMPORTANT: the dump contains the same encrypted columns as the
# live DB (plaid_access_token_enc, totp_secret_enc, etc.). Those
# only decrypt with the live `ENCRYPTION_KEY`. A backup is therefore
# only useful when paired with `.env` — back BOTH up, store the
# `BACKUP_PASSPHRASE` and `ENCRYPTION_KEY` separately, and keep at
# least one off-machine copy.
#
# Usage:
#   BACKUP_PASSPHRASE=<long random string> bash scripts/backup.sh
#
# Env vars (all optional except BACKUP_PASSPHRASE):
#   BACKUP_PASSPHRASE    Required. GPG symmetric passphrase. Generate
#                        once with `openssl rand -base64 48` and store
#                        in a password manager — losing it = losing
#                        the backups.
#   BACKUP_DIR           Output directory. Default ~/patrimonio-backups
#   BACKUP_RETENTION     Number of most-recent dumps to keep.
#                        Default 14 (two weeks of daily backups).
#   COMPOSE_PROJECT      docker-compose project name. Default `patrimonio`
#                        — change when running against a worktree.
#   PG_USER              Postgres role inside the container. Default
#                        `patrimonio` (matches docker-compose.yml).
#   PG_DB                Database name. Default `patrimonio`.

set -euo pipefail

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  echo "ERROR: BACKUP_PASSPHRASE is not set." >&2
  echo "Generate one with: openssl rand -base64 48" >&2
  echo "Store it in a password manager — losing it makes every backup unreadable." >&2
  exit 2
fi

BACKUP_DIR="${BACKUP_DIR:-$HOME/patrimonio-backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-14}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-patrimonio}"
PG_USER="${PG_USER:-patrimonio}"
PG_DB="${PG_DB:-patrimonio}"

mkdir -p "$BACKUP_DIR"

# Find the postgres container for the named compose project. We use
# the `com.docker.compose.project` label rather than a hard-coded name
# so this works against any project the user chose.
container=$(docker ps \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
  --filter "label=com.docker.compose.service=postgres" \
  --format '{{.Names}}' | head -n1)

if [ -z "$container" ]; then
  echo "ERROR: no running postgres container found for compose project '${COMPOSE_PROJECT}'." >&2
  echo "Bring the stack up first: docker compose -p ${COMPOSE_PROJECT} up -d postgres" >&2
  exit 3
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_file="${BACKUP_DIR}/patrimonio-${timestamp}.sql.gpg"
tmp_meta=$(mktemp)
trap 'rm -f "$tmp_meta"' EXIT

echo "backup: source=${container} dest=${out_file}"

# Stream pg_dump → gpg → file. --clean and --if-exists make the dump
# self-restoring (it issues DROP statements before each CREATE), which
# is what we want for "restore over an existing DB" — restore.sh
# additionally drops the whole DB for a known-clean state.
#
# GPG symmetric (AES-256), passphrase from stdin (`--batch
# --passphrase-fd 0`) so it never appears in argv. The compress
# step inside gpg packs the SQL efficiently.
#
# `set -o pipefail` (set at the top of the script) means the pipeline
# fails if EITHER pg_dump or gpg errors out — we don't end up with a
# zero-byte "successful" dump.
docker exec -i "$container" pg_dump \
    --username "$PG_USER" \
    --dbname "$PG_DB" \
    --clean --if-exists --no-owner --no-privileges \
    --format=plain \
  | gpg --batch --quiet --yes \
        --passphrase-fd 3 \
        --symmetric --cipher-algo AES256 --compress-algo zlib \
        --output "$out_file" \
        3<<<"$BACKUP_PASSPHRASE"

# Verify the dump is non-trivial. pg_dump on an empty DB still
# produces ~3 KB of comments; anything under 1 KB means something
# went wrong upstream.
size=$(stat -c%s "$out_file" 2>/dev/null || stat -f%z "$out_file")
if [ "$size" -lt 1024 ]; then
  echo "ERROR: backup file is only ${size} bytes — pg_dump likely failed." >&2
  rm -f "$out_file"
  exit 4
fi

# Sidecar metadata: which migration head was applied, which DB
# version, when the dump was taken. Restore.sh prints this so a
# stale backup is obvious.
docker exec -i "$container" psql -U "$PG_USER" -d "$PG_DB" -At -c \
    "SELECT 'migration_head=' || version FROM _sqlx_migrations ORDER BY version DESC LIMIT 1;" \
    >> "$tmp_meta" 2>/dev/null || true
docker exec -i "$container" psql -U "$PG_USER" -d "$PG_DB" -At -c \
    "SELECT 'pg_version=' || version();" >> "$tmp_meta" 2>/dev/null || true
echo "created_at=${timestamp}" >> "$tmp_meta"
echo "source_project=${COMPOSE_PROJECT}" >> "$tmp_meta"
echo "size_bytes=${size}" >> "$tmp_meta"
cp "$tmp_meta" "${out_file}.meta"

# Retention: keep the N newest dumps + their sidecar files, delete
# the rest. We sort by mtime so a manually-renamed dump is treated
# the same as a script-emitted one.
if [ "$BACKUP_RETENTION" -gt 0 ]; then
  # shellcheck disable=SC2010   # ls is fine for date-stamped, predictable filenames
  ls -1t "$BACKUP_DIR"/patrimonio-*.sql.gpg 2>/dev/null \
    | tail -n "+$((BACKUP_RETENTION + 1))" \
    | while read -r old; do
        rm -f "$old" "${old}.meta"
        echo "backup: pruned ${old}"
      done
fi

# Final sanity: confirm we can decrypt our own output. Catches
# passphrase-shell-quoting issues that would silently produce
# unrecoverable files. We decrypt to a temp file (not a pipe) so the
# verifier never SIGPIPEs gpg mid-stream — that was producing
# spurious failures even on perfectly-good dumps.
verify_tmp=$(mktemp)
trap 'rm -f "$tmp_meta" "$verify_tmp"' EXIT
if ! gpg --batch --quiet --yes \
        --passphrase-fd 3 \
        --output "$verify_tmp" \
        --decrypt "$out_file" 3<<<"$BACKUP_PASSPHRASE" 2>/dev/null; then
  echo "ERROR: round-trip decrypt of fresh backup failed. Check BACKUP_PASSPHRASE." >&2
  exit 5
fi
if ! head -c 1024 "$verify_tmp" | grep -q "PostgreSQL database dump"; then
  echo "ERROR: decrypted bytes don't look like a pg_dump (header missing)." >&2
  exit 5
fi

echo "backup: ok (${size} bytes)"
