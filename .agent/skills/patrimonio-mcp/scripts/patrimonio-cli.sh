#!/usr/bin/env bash
# Portable CLI wrapper for the Patrimonio MCP & CLI binary (`patrimonio_mcp`).
# Resolves the repository root relative to this script, builds the binary if
# not yet compiled, and loads ~/.config/patrimonio-mcp/config.env (chmod 0600).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MANIFEST="$REPO_ROOT/backend/Cargo.toml"

if [[ -x "$REPO_ROOT/backend/target/release/patrimonio_mcp" ]]; then
  BIN="$REPO_ROOT/backend/target/release/patrimonio_mcp"
elif [[ -x "$REPO_ROOT/backend/target/debug/patrimonio_mcp" ]]; then
  BIN="$REPO_ROOT/backend/target/debug/patrimonio_mcp"
else
  CARGO_BIN="${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}"
  "$CARGO_BIN" build --manifest-path "$MANIFEST" --bin patrimonio_mcp >&2
  BIN="$REPO_ROOT/backend/target/debug/patrimonio_mcp"
fi

CONFIG="${PATRIMONIO_MCP_CONFIG_FILE:-$HOME/.config/patrimonio-mcp/config.env}"
if [[ -f "$CONFIG" ]]; then
  exec "$BIN" --config "$CONFIG" "$@"
else
  exec "$BIN" "$@"
fi
