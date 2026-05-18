#!/usr/bin/env bash
# Rotate ENCRYPTION_KEY across every `*_enc` column in the database.
#
# Decrypts each row's ciphertext with OLD_ENCRYPTION_KEY, re-encrypts
# with NEW_ENCRYPTION_KEY, writes back in a single transaction per
# column. Wraps the `rotate_encryption_key` Rust binary that ships in
# the api image — keeps the operator from needing a Rust toolchain.
#
# DESTRUCTIVE in the sense that the old ciphertext is replaced. Keep
# the OLD_ENCRYPTION_KEY in cold storage for ≥30 days in case of
# emergency rollback (a fresh backup taken before the rotation will
# still decrypt with the old key).
#
# Usage:
#   OLD_ENCRYPTION_KEY=$(grep ^ENCRYPTION_KEY= .env | cut -d= -f2) \
#   NEW_ENCRYPTION_KEY=$(openssl rand -hex 32) \
#   bash scripts/rotate-encryption-key.sh
#
# After it succeeds:
#   1. Update ENCRYPTION_KEY in `.env` to the NEW value.
#   2. docker compose -p patrimonio up -d --force-recreate api
#   3. Take a fresh backup so the new ciphertext is on disk.

set -euo pipefail

if [ -z "${OLD_ENCRYPTION_KEY:-}" ] || [ -z "${NEW_ENCRYPTION_KEY:-}" ]; then
  echo "ERROR: OLD_ENCRYPTION_KEY and NEW_ENCRYPTION_KEY must both be set." >&2
  echo "  Generate a new key: openssl rand -hex 32" >&2
  exit 2
fi

COMPOSE_PROJECT="${COMPOSE_PROJECT:-patrimonio}"

# Pre-flight: stop the API so a concurrent sync can't race the
# rotation. Postgres + Redis stay up — we still need DB connectivity
# and the API will re-attach when we bring it back.
echo "rotate: stopping api (so it can't race the rotation)…"
docker compose -p "$COMPOSE_PROJECT" stop api

# Find any container in the project that has the rotate binary +
# DATABASE_URL on hand. The simplest is to run a transient container
# from the same `patrimonio-api` image — that way we don't have to
# bring api back up halfway through.
image=$(docker compose -p "$COMPOSE_PROJECT" config --format json 2>/dev/null \
  | grep -oE '"patrimonio-api[^"]*"' | head -n1 | tr -d '"' || true)
if [ -z "$image" ]; then
  # Fallback for older docker compose: assume the conventional name.
  image="patrimonio-api"
fi

# Reuse the api service's env (DATABASE_URL etc.) by setting them
# explicitly from the .env file the user has already wired up.
postgres_container=$(docker ps \
  --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
  --filter "label=com.docker.compose.service=postgres" \
  --format '{{.Names}}' | head -n1)
if [ -z "$postgres_container" ]; then
  echo "ERROR: postgres container not running for project '${COMPOSE_PROJECT}'." >&2
  echo "Bring it up: docker compose -p ${COMPOSE_PROJECT} up -d postgres" >&2
  exit 3
fi

# Build DATABASE_URL from the postgres container's env so we don't
# rely on a host-side .env file being correct.
db_user=$(docker exec "$postgres_container" sh -c 'echo $POSTGRES_USER')
db_pass=$(docker exec "$postgres_container" sh -c 'echo $POSTGRES_PASSWORD')
db_name=$(docker exec "$postgres_container" sh -c 'echo $POSTGRES_DB')

# Transient container on the same compose network so it can resolve
# the postgres service by name (no host port roundtrip needed).
network=$(docker inspect "$postgres_container" \
  --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')

echo "rotate: running rotate_encryption_key…"
docker run --rm \
  --network "$network" \
  -e DATABASE_URL="postgres://${db_user}:${db_pass}@${postgres_container}:5432/${db_name}" \
  -e OLD_ENCRYPTION_KEY="$OLD_ENCRYPTION_KEY" \
  -e NEW_ENCRYPTION_KEY="$NEW_ENCRYPTION_KEY" \
  "$image" \
  rotate_encryption_key

echo
echo "rotate: ok. Next steps:"
echo "  1. Replace ENCRYPTION_KEY=... in .env with the NEW value."
echo "  2. docker compose -p ${COMPOSE_PROJECT} up -d --force-recreate api"
echo "  3. Sign in + click Sync — a successful Plaid call proves the new key works."
echo "  4. Take a fresh backup. The OLD key is no longer needed for new dumps,"
echo "     but keep it in cold storage for ≥30 days as a rollback safety net."
