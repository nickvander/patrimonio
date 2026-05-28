#!/usr/bin/env bash
# Run the backend cargo test suite inside a docker container, against
# a Postgres database created on the running `patrimonio-postgres-1`.
#
# Why a wrapper:
#   * The integration tests in tests/dashboard_endpoints.rs and
#     tests/auth_endpoints.rs need a real Postgres reachable via
#     PATRIMONIO_TEST_DATABASE_URL — they skip with a print otherwise.
#   * The tests share a single DB and TRUNCATE on setup. Two layers
#     of coordination:
#       - `#[serial_test::serial]` on every `#[tokio::test]` serialises
#         within ONE binary (process-local mutex).
#       - `TestLockGuard` in `tests/common/mod.rs` holds a Postgres
#         advisory lock for the duration of each test, which
#         serialises ACROSS binaries (cargo runs test binaries in
#         parallel by default).
#     Plain `cargo test` Just Works with both layers in place. The
#     --test-threads=1 pin stays as belt-and-braces — if a new test
#     forgets either, the pin keeps the suite green until it's caught.
#   * The rust:1.88-slim image doesn't bundle libssl-dev / pkg-config,
#     so the linker fails without an apt-get install step first.
#
# This script builds a small "patrimonio-test" image (cached after
# first run) that bakes in the apt deps, then runs cargo test with
# the right env wiring. Extra args are passed through:
#
#   ./scripts/test.sh                       # full suite
#   ./scripts/test.sh --test dashboard_endpoints
#   ./scripts/test.sh -- --nocapture       # `--` ends our flags
set -euo pipefail

# Resolve the repo root from the script location so it works regardless
# of where the caller invokes from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-patrimonio-postgres-1}"
POSTGRES_USER="${POSTGRES_USER:-patrimonio}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-patrimonio}"
POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-5433}"
TEST_DB="${TEST_DB:-patrimonio_test}"
TEST_IMAGE="${TEST_IMAGE:-patrimonio-test}"

# Make sure the Postgres container is up. We don't try to start it —
# the integration tests assume the dev stack is running anyway.
if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    echo "error: ${POSTGRES_CONTAINER} is not running." >&2
    echo "Bring the dev stack up first:  docker compose -p patrimonio up -d" >&2
    exit 1
fi

# Idempotent: create the test database if absent. The role owning the
# main 'patrimonio' DB also owns the test one, so we don't have to
# manage credentials separately.
echo "→ ensuring test DB exists: ${TEST_DB}"
docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d postgres -tc \
    "SELECT 1 FROM pg_database WHERE datname='${TEST_DB}'" \
    | grep -q 1 || \
docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d postgres -c \
    "CREATE DATABASE ${TEST_DB} OWNER ${POSTGRES_USER}"

# Build the test image on first invocation. Subsequent runs reuse the
# cached layer — apt-get only runs once per Rust toolchain bump.
if ! docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
    echo "→ building ${TEST_IMAGE} (one-time, ~30 s)"
    docker build -q -t "$TEST_IMAGE" -<<'DOCKERFILE'
FROM rust:1.88-slim
RUN apt-get update -qq \
 && apt-get install -y -qq pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
DOCKERFILE
fi

echo "→ cargo test -- --test-threads=1 $*"
exec docker run --rm \
    --network host \
    -v "${REPO_ROOT}/backend:/app" \
    -e PATRIMONIO_TEST_DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_HOST_PORT}/${TEST_DB}" \
    -e SQLX_OFFLINE=true \
    "$TEST_IMAGE" \
    cargo test "$@" -- --test-threads=1
