# AI Agent Access (MCP Server & CLI)

Patrimonio ships with a built-in **Model Context Protocol (MCP) server and CLI** (`patrimonio_mcp`) in `backend/src/bin/patrimonio_mcp.rs` along with a reusable agent skill in `.agent/skills/patrimonio-mcp/SKILL.md`.

It lets AI coding/finance assistants (Claude Desktop, Claude Code, Gemini / Antigravity, Cursor) answer questions about your net worth, attribution movers, institution sync health, transactions, holdings/lots, and personal loans **without ever having access to your encrypted Plaid tokens, password hashes, or session credentials**.

---

## Security Architecture (Defense in Depth)

Connecting an LLM agent to a personal finance database requires strict boundaries. `patrimonio_mcp` enforces five layers of protection:

1. **Engine-Enforced Least Privilege (`patrimonio_mcp_ro`)**
   `scripts/setup_mcp_role.sql` provisions a dedicated PostgreSQL role (`patrimonio_mcp_ro`) with:
   - `default_transaction_read_only = on`
   - `statement_timeout = '10s'`, `lock_timeout = '2s'`, and `idle_in_transaction_session_timeout = '10s'`
   - **Zero access** (`REVOKE ALL`) to authentication/credential tables: `passkey_credentials`, `recovery_codes`, `user_sessions`, `invite_tokens`, `auth_audit`, and `_sqlx_migrations`.
   - **Column-level `SELECT` grants** on `users` and `institutions` that explicitly exclude `password_hash`, `totp_secret_enc`, `plaid_access_token_enc`, `api_key_enc`, `api_secret_enc`, `api_pass_enc`, and `plaid_transactions_cursor`. Even if a query attempts to read those columns, PostgreSQL rejects it with `permission denied`.

2. **Session-Level Read-Only Guard**
   Every connection in the read pool executes `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`, `SET statement_timeout = '10s'`, and `SET lock_timeout = '2s'` inside `sqlx`'s `after_connect` hook—even when connected to a local dev database.

3. **Externalized, Permission-Checked Config (`chmod 0600`)**
   Database credentials live in `~/.config/patrimonio-mcp/config.env` rather than in `mcp_config.json` or command-line arguments. On Unix, `patrimonio_mcp` verifies that the file is not group- or world-readable (`mode & 0o077 == 0`) before loading it.

4. **Built-In Ephemeral SSH Tunneling**
   If your Patrimonio stack runs on a remote homelab with Postgres bound to `127.0.0.1:5433`, set `PATRIMONIO_SSH_HOST=<your-host>`. `patrimonio_mcp` automatically spawns a loopback-only (`127.0.0.1:<ephemeral_port>`) SSH port forward on first query and tears it down on exit.

5. **Domain-Accurate Financial Math & Gated Mutations**
   - Reuses `patrimonio::services::fx` (`LATEST_USD_MXN_RATE_SQL`, `USD_MXN_ROW_RATE_SQL`, `AMOUNT_USD_SQL`) so MXN accounts are converted to USD per row and never summed raw.
   - Uses Patrimonio's carry-forward algorithm across `balance_snapshots` (never naive `GROUP BY as_of_date`).
   - Mutating tools (`reconcile_loan_installment`) default to `dry_run: true`, require `PATRIMONIO_MCP_ALLOW_WRITES=true` plus a separate `PATRIMONIO_WRITE_DATABASE_URL` to commit, and log every call to `~/.config/patrimonio-mcp/audit.jsonl`.

---

## Setup Guide

### Step 1: Provision the `patrimonio_mcp_ro` PostgreSQL Role

Generate a random password and run `scripts/setup_mcp_role.sql` against your Patrimonio PostgreSQL database:

=== "Docker Compose (Local or Remote Host)"

    ```bash
    MCP_PASS="$(openssl rand -hex 24)"
    docker exec -i -u postgres patrimonio-postgres-1 \
      psql -U patrimonio -d patrimonio -v mcp_password="'$MCP_PASS'" \
      < scripts/setup_mcp_role.sql
    echo "Provisioned patrimonio_mcp_ro password: $MCP_PASS"
    ```

=== "Local Native Postgres"

    ```bash
    MCP_PASS="$(openssl rand -hex 24)"
    psql -h 127.0.0.1 -p 5442 -U patrimonio -d patrimonio \
      -v mcp_password="'$MCP_PASS'" \
      -f scripts/setup_mcp_role.sql
    echo "Provisioned patrimonio_mcp_ro password: $MCP_PASS"
    ```

### Step 2: Create `~/.config/patrimonio-mcp/config.env`

Create the `0600` configuration file outside your git checkout:

```bash
mkdir -p ~/.config/patrimonio-mcp
chmod 700 ~/.config/patrimonio-mcp

cat > ~/.config/patrimonio-mcp/config.env <<'EOF'
# Option A: Direct PostgreSQL connection (when running on the same machine)
# PATRIMONIO_MCP_DATABASE_URL=postgres://patrimonio_mcp_ro:<MCP_PASS>@127.0.0.1:5433/patrimonio

# Option B: Automatic loopback SSH port-forward to a remote homelab host
PATRIMONIO_SSH_HOST=your-homelab-ssh-alias
PATRIMONIO_SSH_REMOTE_PORT=5433
PATRIMONIO_DB_USER=patrimonio_mcp_ro
PATRIMONIO_DB_PASSWORD=<MCP_PASS>
PATRIMONIO_DB_NAME=patrimonio

# Optional: pin user UUID if your instance has multiple active users
# PATRIMONIO_MCP_USER_ID=<your-user-uuid>

# Keep writes disabled by default (read-only mode)
PATRIMONIO_MCP_ALLOW_WRITES=false
PATRIMONIO_MCP_AUDIT_LOG=/home/<you>/.config/patrimonio-mcp/audit.jsonl
EOF

chmod 600 ~/.config/patrimonio-mcp/config.env
```

### Step 3: Build & Run the Security Self-Test

```bash
cd backend
cargo build --release --bin patrimonio_mcp
./target/release/patrimonio_mcp --self-test
```

`--self-test` verifies that:

1. `~/.config/patrimonio-mcp/config.env` permissions are `0600`.
2. The database connection (and SSH tunnel, if configured) succeeds.
3. `SELECT plaid_access_token_enc FROM institutions` is **denied** by PostgreSQL.
4. `SELECT password_hash FROM users` is **denied** by PostgreSQL.
5. `DELETE` statements are **denied** by PostgreSQL's read-only transaction mode.
6. `get_net_worth_summary` and `audit_data_health` execute cleanly.

Optionally symlink the binary onto your `$PATH` for direct CLI usage:

```bash
ln -sf "$(pwd)/target/release/patrimonio_mcp" ~/.local/bin/patrimonio-mcp
```

---

## Registering the MCP Server in Your Agent

Add `patrimonio` to your MCP client configuration (e.g., `~/.gemini/config/mcp_config.json`, Claude Desktop's `claude_desktop_config.json`, or `.mcp.json`):

```json
{
  "mcpServers": {
    "patrimonio": {
      "command": "/absolute/path/to/patrimonio/backend/target/release/patrimonio_mcp",
      "args": [
        "--config",
        "/home/your-user/.config/patrimonio-mcp/config.env"
      ]
    }
  }
}
```

Notice that **no passwords or tokens appear in `mcp_config.json`**.

---

## Available MCP Tools

| Tool | Mode | Description |
| :--- | :--- | :--- |
| `get_net_worth_summary` | Read-only | Net worth in USD & MXN, live USD/MXN FX rate + staleness flag, currency and institution breakdowns. |
| `get_net_worth_history_and_movers` | Read-only | Carry-forward daily net worth series between `start_date` and `end_date` plus top per-account USD gainers/losers. |
| `list_accounts_and_sync_health` | Read-only | All active/archived accounts with Plaid `sync_status`, `last_sync_error`, manual import age, and actionable recommendations. |
| `search_transactions` | Read-only | Parameterized transaction search (`1..=200` rows) with per-row USD conversion via `USD_MXN_ROW_RATE_SQL`. |
| `get_holdings_and_lots` | Read-only | Active investment holdings, share quantities, prices, cost basis, unrealized P&L, and optional tax lots. |
| `get_loans_and_payments` | Read-only | Loans, repayment schedules, and automatic detection of out-of-order or overdue installments. |
| `audit_data_health` | Read-only | One-call health audit across Plaid syncs, manual imports, missing snapshots, loan schedules, and unread notifications. |
| `reconcile_loan_installment` | Dry-run default | Previews (`dry_run: true`) or updates (`dry_run: false`, requires `PATRIMONIO_MCP_ALLOW_WRITES=true`) a loan installment with JSONL audit logging. |

---

## CLI Usage (`patrimonio-mcp`)

The same binary doubles as a fast CLI for terminal inspection or agent skill scripts:

```bash
# Net worth summary
patrimonio-mcp summary

# Carry-forward net worth history & top movers over a date range
patrimonio-mcp movers --start 2026-10-01 --end 2026-10-25 --top 10

# List only accounts with sync/import issues or archived status
patrimonio-mcp accounts --issues

# Search transactions
patrimonio-mcp transactions --query "Rent" --limit 20

# View holdings and tax lots
patrimonio-mcp holdings --symbol VOO --lots

# Inspect loans and repayment schedules
patrimonio-mcp loans --status active

# Run full diagnostic audit
patrimonio-mcp audit
```
