# AI Agent Access (MCP Server & CLI)

Patrimonio ships with a built-in **Model Context Protocol (MCP) server and CLI**:

- **Streamable HTTP MCP Endpoint (`POST /api/mcp`)**: Built directly into the Patrimonio backend (`backend/src/api/mcp.rs` + `backend/src/mcp.rs`), authenticated with scoped **Personal Access Tokens (`pat_...`)**.
- **Local `stdio` MCP Server & CLI (`patrimonio_mcp`)**: Built from `backend/src/bin/patrimonio_mcp.rs`, which can connect either via **Personal Access Token over HTTPS** (`patrimonio-mcp login --url https://...`) or via a **least-privilege PostgreSQL role (`patrimonio_mcp_ro`)**.
- **Reusable Agent Skill**: Located at `.agent/skills/patrimonio-mcp/SKILL.md`.

It lets AI coding/finance assistants (Claude Desktop, Claude Code, Gemini / Antigravity, Cursor) answer questions about your net worth, attribution movers, institution sync health, transactions, holdings/lots, and personal loans **without ever having access to your encrypted Plaid tokens, password hashes, or session credentials**.

---

## How Users Authenticate (3 Scalable Modes)

Patrimonio supports three ways to authenticate an AI agent or CLI, depending on how your instance is deployed:

| Mode | Best For | How It Works | Requires SSH / DB Access? |
| :--- | :--- | :--- | :--- |
| **1. `patrimonio-mcp login` (Personal Access Token + CLI/stdio)** | **Most users & contributors** | Run `patrimonio-mcp login --url https://patrimonio.example.com`. Signs in with your username/password (+ 2FA TOTP if enabled), mints a `read_only` Personal Access Token (`pat_...`), revokes the temporary login session, and saves the token to `~/.config/patrimonio-mcp/config.env` (`chmod 0600`). | **No** |
| **2. Direct Streamable HTTP MCP (`POST /api/mcp`)** | **Remote / Cloud MCP clients** | Point any Streamable HTTP MCP client directly at `https://patrimonio.example.com/api/mcp` with header `Authorization: Bearer pat_<token>`. | **No** |
| **3. Direct Read-Only PostgreSQL (`patrimonio_mcp_ro`)** | **Self-hosted homelab operators** | Connects `patrimonio_mcp` directly (or via automatic loopback SSH tunnel) to PostgreSQL using the restricted `patrimonio_mcp_ro` role (`scripts/setup_mcp_role.sql`). | Yes (SSH or local DB) |

---

## Security Architecture (Defense in Depth)

1. **Scoped Personal Access Tokens (`pat_...`)**
   - Stored in `user_api_tokens` as **SHA-256 hashes** (`token_hash BYTEA`) — the raw `pat_<base64url>` secret is returned once at creation and never stored in plaintext.
   - Scoped to **`read_only` by default**: even if an `owner` user creates a `read_only` token, the backend's `require_auth` middleware downgrades `AuthContext.role` to `"read_only"` for that request, blocking all mutating REST routes (`require_owner`) and MCP write tools.
   - **Account-Management Isolation (`reject_api_token_account_mgmt`)**: A `pat_...` token is strictly blocked from calling credential or session management endpoints (`/api/auth/tokens`, `/api/auth/change-password`, `/api/auth/totp/*`, `/api/auth/passkeys/*`, `/api/auth/sessions/*`). A leaked API token can never mint new tokens, change passwords, or escalate privileges.
   - **Instant Revocation & Expiry**: Tokens default to a 90-day expiry (configurable from 1–3650 days) and can be listed (`GET /api/auth/tokens`) or revoked (`DELETE /api/auth/tokens/{id}`) at any time.

2. **Engine-Enforced Least Privilege (`patrimonio_mcp_ro`) for Direct DB Mode**
   `scripts/setup_mcp_role.sql` provisions a dedicated PostgreSQL role (`patrimonio_mcp_ro`) with:
   - `default_transaction_read_only = on`
   - `statement_timeout = '10s'`, `lock_timeout = '2s'`, and `idle_in_transaction_session_timeout = '10s'`
   - **Zero access** (`REVOKE ALL`) to authentication/credential tables: `passkey_credentials`, `recovery_codes`, `user_sessions`, `user_api_tokens`, `invite_tokens`, `auth_audit`, and `_sqlx_migrations`.
   - **Column-level `SELECT` grants** on `users` and `institutions` that explicitly exclude `password_hash`, `totp_secret_enc`, `plaid_access_token_enc`, `api_key_enc`, `api_secret_enc`, `api_pass_enc`, and `plaid_transactions_cursor`.

3. **Externalized, Permission-Checked Config (`chmod 0600`)**
   Credentials live in `~/.config/patrimonio-mcp/config.env` rather than in `mcp_config.json` or command-line arguments. On Unix, `patrimonio_mcp` verifies that the file is not group- or world-readable (`mode & 0o077 == 0`) before loading it.

4. **Domain-Accurate Financial Math & Gated Mutations**
   - Reuses `patrimonio::services::fx` (`LATEST_USD_MXN_RATE_SQL`, `USD_MXN_ROW_RATE_SQL`, `AMOUNT_USD_SQL`) so MXN accounts are converted to USD per row and never summed raw.
   - Uses Patrimonio's carry-forward algorithm across `balance_snapshots` (never naive `GROUP BY as_of_date`).
   - Mutating tools (`reconcile_loan_installment`) default to `dry_run: true` and require an owner-scoped `read_write` token (or `PATRIMONIO_MCP_ALLOW_WRITES=true` + `PATRIMONIO_WRITE_DATABASE_URL` in DB mode).

---

## Quickstart A: Authenticate with `patrimonio-mcp login` (Recommended)

No database passwords or SSH access needed — works for any Patrimonio user account:

```bash
# 1. Build the CLI / MCP binary
cd backend
cargo build --release --bin patrimonio_mcp
ln -sf "$(pwd)/target/release/patrimonio_mcp" ~/.local/bin/patrimonio-mcp

# 2. Authenticate interactively (prompts for username, password, and 2FA TOTP if enabled)
patrimonio-mcp login --url https://patrimonio.example.com

# 3. Verify connection and run a quick check
patrimonio-mcp --self-test
patrimonio-mcp summary
```

What `patrimonio-mcp login` does under the hood:
1. Authenticates against `POST /api/auth/login` (and `POST /api/auth/totp/verify` if 2FA is enabled on your account).
2. Calls `POST /api/auth/tokens` to mint a `read_only` Personal Access Token (`pat_...`, 90-day default expiry).
3. Calls `POST /api/auth/logout` so the temporary login cookie is immediately revoked.
4. Writes `PATRIMONIO_API_URL` and `PATRIMONIO_API_TOKEN` to `~/.config/patrimonio-mcp/config.env` with `chmod 0600`.

### Managing Personal Access Tokens via API

You can also list, create, or revoke tokens directly with an authenticated session:

```bash
# List active Personal Access Tokens (prefixes, scopes, last_used_at, expires_at)
GET /api/auth/tokens

# Mint a new Personal Access Token
POST /api/auth/tokens
Content-Type: application/json
X-Requested-With: patrimonio

{
  "name": "Claude Desktop",
  "scope": "read_only",
  "expires_in_days": 90
}

# Revoke a token by UUID
DELETE /api/auth/tokens/{id}
X-Requested-With: patrimonio
```

---

## Quickstart B: Direct Read-Only PostgreSQL (`patrimonio_mcp_ro`)

For homelab operators who want direct PostgreSQL isolation over loopback or SSH:

### Step 1: Provision the `patrimonio_mcp_ro` PostgreSQL Role

```bash
MCP_PASS="$(openssl rand -hex 24)"
docker exec -i -u postgres patrimonio-postgres-1 \
  psql -U patrimonio -d patrimonio -v mcp_password="'$MCP_PASS'" \
  < scripts/setup_mcp_role.sql
echo "Provisioned patrimonio_mcp_ro password: $MCP_PASS"
```

### Step 2: Create `~/.config/patrimonio-mcp/config.env`

```bash
mkdir -p ~/.config/patrimonio-mcp
chmod 700 ~/.config/patrimonio-mcp

cat > ~/.config/patrimonio-mcp/config.env <<'EOF'
# Option 1: Personal Access Token over HTTPS (set automatically by `patrimonio-mcp login`)
# PATRIMONIO_API_URL=https://patrimonio.example.com
# PATRIMONIO_API_TOKEN=pat_<your-token>

# Option 2: Direct PostgreSQL connection (when running on the same machine)
# PATRIMONIO_MCP_DATABASE_URL=postgres://patrimonio_mcp_ro:<MCP_PASS>@127.0.0.1:5433/patrimonio

# Option 3: Automatic loopback SSH port-forward to a remote homelab host
PATRIMONIO_SSH_HOST=your-homelab-ssh-alias
PATRIMONIO_SSH_REMOTE_PORT=5433
PATRIMONIO_DB_USER=patrimonio_mcp_ro
PATRIMONIO_DB_PASSWORD=<MCP_PASS>
PATRIMONIO_DB_NAME=patrimonio

# Keep writes disabled by default (read-only mode)
PATRIMONIO_MCP_ALLOW_WRITES=false
EOF

chmod 600 ~/.config/patrimonio-mcp/config.env
```

---

## Registering the MCP Server in Your Agent

### Option 1: Local `stdio` Binary (Works with both `patrimonio-mcp login` and DB Mode)

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

### Option 2: Streamable HTTP Endpoint (`POST /api/mcp`)

For MCP clients that support remote HTTP servers with Bearer token authentication:

```json
{
  "mcpServers": {
    "patrimonio": {
      "url": "https://patrimonio.example.com/api/mcp",
      "headers": {
        "Authorization": "Bearer pat_<your-token>"
      }
    }
  }
}
```

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
| `reconcile_loan_installment` | Dry-run default | Previews (`dry_run: true`) or updates (`dry_run: false`) a loan installment with audit logging. |

---

## CLI Usage (`patrimonio-mcp`)

The same binary doubles as a fast CLI for terminal inspection or agent skill scripts:

```bash
# Authenticate and save a Personal Access Token (pat_...)
patrimonio-mcp login --url https://patrimonio.example.com

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
