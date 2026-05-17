#!/usr/bin/env bash
# Ensures the current worktree has a local .env so docker-compose can
# resolve secrets like ENCRYPTION_KEY and PLAID_*. New worktrees come up
# without one, which silently turns every Plaid sync into "Encryption
# key missing" until someone notices.
#
# Resolution order:
#   1. If ./.env already exists or is a symlink → nothing to do.
#   2. Walk up the directory tree looking for an .env in any ancestor.
#   3. If found, symlink it into the worktree.
#   4. Otherwise, copy .env.example to .env so docker-compose at least
#      reads valid empty defaults rather than complaining about a
#      missing file.

set -euo pipefail

# Operate on the caller's CWD rather than the script's directory so that
# `bash /path/to/main/scripts/setup-env.sh` invoked from a worktree
# resolves to the worktree's .env, not main's.
local_env="$(pwd)/.env"

if [[ -e "$local_env" ]]; then
  echo ".env already present at $local_env"
  exit 0
fi

# Walk up the tree. We stop at $HOME or filesystem root, whichever
# comes first, to avoid resolving someone else's .env outside the user's
# home.
dir="$(pwd)"
while [[ "$dir" != "/" && "$dir" != "$HOME/.." ]]; do
  parent="$(dirname "$dir")"
  candidate="$parent/.env"
  if [[ -f "$candidate" || -L "$candidate" ]]; then
    ln -s "$candidate" "$local_env"
    echo "Linked $local_env → $candidate"
    exit 0
  fi
  dir="$parent"
done

if [[ -f .env.example ]]; then
  cp .env.example .env
  echo "No ancestor .env found; seeded .env from .env.example (all values empty)"
  echo "Edit $local_env to add ENCRYPTION_KEY / PLAID_* etc. before relinking accounts."
  exit 0
fi

echo "Could not find an .env in any parent directory and no .env.example exists." >&2
exit 1
