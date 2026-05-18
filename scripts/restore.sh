#!/usr/bin/env bash
# Patrimonio restore script — decrypt + replay an encrypted pg_dump.
#
# Pairs with scripts/backup.sh. Steps:
#   1. Decrypt the .sql.gpg file with BACKUP_PASSPHRASE (stdin only —
#      never on argv).
#   2. Drop and recreate the target database so we start from a known
#      empty state (the dump includes its own DROP/CREATE TABLE
#      statements but RLS policies, sequences, and orphaned objects
#      can survive otherwise).
#   3. Pipe the SQL into psql. Errors stop the restore (--set
#      ON_ERROR_STOP=on) so a half-applied dump never silently lands.
#
# Usage:
#   BACKUP_PASSPHRASE=<...> bash scripts/restore.sh <dump-file>
#
# Optional flags:
#   --project NAME   docker-compose project to restore into.
#                    Default `patrimonio` (the live stack).
#                    Use a separate name (e.g. patrimonio-restore-test)
#                    to test restores without touching live data.
#   --yes            Skip the interactive confirmation. Required for
#                    cron / automation. Without it we prompt with the
#                    name of the project being clobbered.
#
# Env vars:
#   BACKUP_PASSPHRASE  Required. Same passphrase used at backup time.
#   PG_USER            Postgres role. Default `patrimonio`.
#   PG_DB              Database name. Default `patrimonio`.

set -euo pipefail

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  echo "ERROR: BACKUP_PASSPHRASE is not set." >&2
  exit 2
fi

dump_file=""
project="patrimonio"
assume_yes="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      project="$2"
      shift 2
      ;;
    --yes|-y)
      assume_yes="yes"
      shift
      ;;
    -h|--help)
      sed -n '1,40p' "$0"   # print this script's header
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 64
      ;;
    *)
      if [ -z "$dump_file" ]; then
        dump_file="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 64
      fi
      shift
      ;;
  esac
done

if [ -z "$dump_file" ]; then
  echo "Usage: BACKUP_PASSPHRASE=<...> $0 [--project NAME] [--yes] <dump-file.sql.gpg>" >&2
  exit 64
fi
if [ ! -f "$dump_file" ]; then
  echo "ERROR: dump file not found: ${dump_file}" >&2
  exit 65
fi

PG_USER="${PG_USER:-patrimonio}"
PG_DB="${PG_DB:-patrimonio}"

# Find the postgres container for the destination project.
container=$(docker ps \
  --filter "label=com.docker.compose.project=${project}" \
  --filter "label=com.docker.compose.service=postgres" \
  --format '{{.Names}}' | head -n1)
if [ -z "$container" ]; then
  echo "ERROR: no running postgres container for compose project '${project}'." >&2
  echo "Bring it up first: docker compose -p ${project} up -d postgres" >&2
  exit 3
fi

# Show the sidecar metadata if present — so the operator knows
# what they're about to overwrite onto what.
if [ -f "${dump_file}.meta" ]; then
  echo "Restore source metadata:"
  sed 's/^/  /' "${dump_file}.meta"
fi

echo
echo "About to:"
echo "  1. DROP DATABASE ${PG_DB} (every row, every user, every session) on container ${container}"
echo "  2. Recreate empty ${PG_DB}"
echo "  3. Replay $(stat -c%s "$dump_file" 2>/dev/null || stat -f%z "$dump_file") bytes of dump"
echo

if [ "$assume_yes" != "yes" ]; then
  printf 'Continue? Type "yes" to proceed: '
  read -r confirm
  if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 130
  fi
fi

# 1. Disconnect anything currently in `patrimonio` and drop it.
#    Without `pg_terminate_backend` an active api container holding
#    a connection would prevent DROP DATABASE.
docker exec -i "$container" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=on <<SQL
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${PG_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${PG_DB}";
CREATE DATABASE "${PG_DB}" OWNER "${PG_USER}";
SQL

# 2. Pipe decrypt → psql. Two separate processes; pipefail
#    (set -o pipefail above) means either failure aborts.
gpg --batch --quiet --yes \
      --passphrase-fd 3 \
      --decrypt "$dump_file" 3<<<"$BACKUP_PASSPHRASE" \
  | docker exec -i "$container" psql \
      -U "$PG_USER" -d "$PG_DB" \
      --set ON_ERROR_STOP=on \
      --quiet \
  > /tmp/patrimonio-restore.log 2>&1 || {
    echo "ERROR: restore failed. Last 30 lines of log:" >&2
    tail -n 30 /tmp/patrimonio-restore.log >&2
    exit 6
  }

# 3. Smoke check: pull a couple of row counts so the operator can
#    eyeball whether the dump landed.
echo
echo "Restore complete. Smoke counts:"
docker exec -i "$container" psql -U "$PG_USER" -d "$PG_DB" -At <<'SQL' | sed 's/^/  /'
SELECT 'users=' || COUNT(*) FROM users;
SELECT 'institutions=' || COUNT(*) FROM institutions;
SELECT 'accounts=' || COUNT(*) FROM accounts;
SELECT 'transactions=' || COUNT(*) FROM transactions;
SELECT 'balance_snapshots=' || COUNT(*) FROM balance_snapshots;
SELECT 'holdings=' || COUNT(*) FROM holdings;
SELECT 'migration_head=' || MAX(version) FROM _sqlx_migrations;
SQL

echo
echo "Next: restart the api so its connection pool sees the new DB —"
echo "  docker compose -p ${project} restart api"
