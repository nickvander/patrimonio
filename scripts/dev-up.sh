#!/usr/bin/env bash
# Bring the local stack up. Wraps `docker compose -p patrimonio up
# -d --build` with the env-discovery step from setup-env.sh, so a new
# worktree picks up Plaid / encryption secrets without the user having
# to remember to symlink .env first.
#
# Any extra args are forwarded to docker compose, so
#   bash scripts/dev-up.sh frontend api
# rebuilds only those services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/setup-env.sh"

docker compose -p patrimonio up -d --build "$@"
