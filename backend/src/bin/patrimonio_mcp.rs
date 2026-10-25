//! Patrimonio Model Context Protocol (MCP) Server (`patrimonio_mcp`).
//!
//! Exposes a read-first, security-hardened MCP interface over `stdio` so AI
//! agents can inspect net worth, carry-forward history, attribution movers,
//! institution sync health, transactions, holdings/lots, and loans without
//! ever touching raw credentials or risking cross-currency / snapshot bugs.
//!
//! ## Security Architecture (Defense in Depth)
//! 1. **Externalized, Permission-Checked Credentials**: Reads configuration
//!    from `~/.config/patrimonio-mcp/config.env` (must be `0600` on Unix) so
//!    zero passwords or tokens ever appear in `mcp_config.json`, git, or `ps`.
//! 2. **Least-Privilege PostgreSQL Role (`patrimonio_mcp_ro`)**: Paired with
//!    `scripts/setup_mcp_role.sql`, which revokes table-wide access on `users`
//!    and `institutions` and grants column-level `SELECT` only on non-secret
//!    columns — PostgreSQL itself refuses access to `plaid_access_token_enc`,
//!    `password_hash`, `totp_secret_enc`, `passkey_credentials`, `user_sessions`,
//!    `recovery_codes`, and `invite_tokens`.
//! 3. **Session-Level Read-Only & Timeouts**: Every connection in the read pool
//!    executes `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`,
//!    `SET statement_timeout = '10s'`, and `SET lock_timeout = '2s'` inside
//!    `after_connect`.
//! 4. **Strict Tenant Isolation & Parameterized SQL**: Every query binds
//!    `WHERE user_id = $1` with runtime `sqlx::query(...)` binds — never string
//!    interpolation of caller parameters.
//! 5. **Gated, Audited Mutations**: Mutating tools (`reconcile_loan_installment`)
//!    default to `dry_run: true`, require `PATRIMONIO_MCP_ALLOW_WRITES=true` +
//!    a separate `PATRIMONIO_WRITE_DATABASE_URL` to execute for real, and write
//!    an append-only JSONL audit trail (`PATRIMONIO_MCP_AUDIT_LOG`).

use anyhow::{anyhow, bail, Context, Result};
use chrono::{NaiveDate, Utc};
use patrimonio::services::fx::{
    latest_usd_mxn_rate_for_write, AMOUNT_USD_SQL, USD_MXN_ROW_RATE_SQL,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, Executor, PgPool, Row};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, OpenOptions};
use std::io::Write as IoWrite;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::OnceCell;
use uuid::Uuid;

const SERVER_NAME: &str = "patrimonio-mcp";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_PROTOCOL_VERSION: &str = "2024-11-05";
const MAX_SEARCH_LIMIT: i64 = 200;
const DEFAULT_SEARCH_LIMIT: i64 = 50;

#[derive(Debug, Clone)]
struct McpConfig {
    database_url: Option<String>,
    ssh_host: Option<String>,
    ssh_remote_port: u16,
    db_user: String,
    db_password: String,
    db_name: String,
    user_id: Option<Uuid>,
    allow_writes: bool,
    write_database_url: Option<String>,
    audit_log_path: PathBuf,
}

impl McpConfig {
    fn load(config_path: Option<PathBuf>) -> Result<Self> {
        let resolved_path = config_path.or_else(|| {
            std::env::var("PATRIMONIO_MCP_CONFIG_FILE")
                .ok()
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var("HOME").ok().map(|h| {
                        PathBuf::from(h)
                            .join(".config")
                            .join("patrimonio-mcp")
                            .join("config.env")
                    })
                })
        });

        let mut file_vars: HashMap<String, String> = HashMap::new();
        if let Some(ref path) = resolved_path {
            if path.exists() {
                verify_config_permissions(path)?;
                let content = fs::read_to_string(path)
                    .with_context(|| format!("Failed to read config file {}", path.display()))?;
                for raw_line in content.lines() {
                    let line = raw_line.trim();
                    if line.is_empty() || line.starts_with('#') {
                        continue;
                    }
                    if let Some((k, v)) = line.split_once('=') {
                        let key = k.trim().to_string();
                        let val = v.trim().trim_matches('"').trim_matches('\'').to_string();
                        file_vars.insert(key, val);
                    }
                }
            }
        }

        let get_var = |key: &str| -> Option<String> {
            std::env::var(key)
                .ok()
                .filter(|v| !v.trim().is_empty())
                .or_else(|| file_vars.get(key).cloned().filter(|v| !v.trim().is_empty()))
        };

        let database_url =
            get_var("PATRIMONIO_MCP_DATABASE_URL").or_else(|| get_var("DATABASE_URL"));
        let ssh_host = get_var("PATRIMONIO_SSH_HOST");
        let ssh_remote_port = get_var("PATRIMONIO_SSH_REMOTE_PORT")
            .and_then(|s| s.parse::<u16>().ok())
            .unwrap_or(5433);
        let db_user =
            get_var("PATRIMONIO_DB_USER").unwrap_or_else(|| "patrimonio_mcp_ro".to_string());
        let db_password = get_var("PATRIMONIO_DB_PASSWORD").unwrap_or_default();
        let db_name = get_var("PATRIMONIO_DB_NAME").unwrap_or_else(|| "patrimonio".to_string());
        let user_id = match get_var("PATRIMONIO_MCP_USER_ID") {
            Some(s) => Some(
                Uuid::parse_str(&s)
                    .with_context(|| format!("Invalid UUID in PATRIMONIO_MCP_USER_ID: {s}"))?,
            ),
            None => None,
        };
        let allow_writes = get_var("PATRIMONIO_MCP_ALLOW_WRITES")
            .is_some_and(|v| v.eq_ignore_ascii_case("true") || v == "1");
        let write_database_url = get_var("PATRIMONIO_WRITE_DATABASE_URL");
        let audit_log_path = get_var("PATRIMONIO_MCP_AUDIT_LOG")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                PathBuf::from(home)
                    .join(".config")
                    .join("patrimonio-mcp")
                    .join("audit.jsonl")
            });

        Ok(Self {
            database_url,
            ssh_host,
            ssh_remote_port,
            db_user,
            db_password,
            db_name,
            user_id,
            allow_writes,
            write_database_url,
            audit_log_path,
        })
    }
}

/// Refuse to load a credentials file that is group- or world-readable on Unix
/// unless explicitly overridden. This prevents accidental `chmod 644` exposure
/// on multi-user systems.
fn verify_config_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let allow_insecure = std::env::var("PATRIMONIO_MCP_ALLOW_INSECURE_PERMS")
            .is_ok_and(|v| v.eq_ignore_ascii_case("true") || v == "1");
        if !allow_insecure {
            let meta = fs::metadata(path)?;
            let mode = meta.permissions().mode() & 0o777;
            if mode & 0o077 != 0 {
                bail!(
                    "Config file {} has insecure permissions {:04o}; expected 0600 (run `chmod 600 {}`)",
                    path.display(),
                    mode,
                    path.display()
                );
            }
        }
    }
    Ok(())
}

struct DbRuntime {
    pool: PgPool,
    user_id: Uuid,
    _ssh_tunnel: Option<Child>,
}

struct McpServer {
    config: McpConfig,
    db_cell: OnceCell<DbRuntime>,
}

impl McpServer {
    fn new(config: McpConfig) -> Self {
        Self {
            config,
            db_cell: OnceCell::new(),
        }
    }

    async fn db(&self) -> Result<&DbRuntime> {
        self.db_cell
            .get_or_try_init(|| async { self.init_db().await })
            .await
    }

    async fn init_db(&self) -> Result<DbRuntime> {
        let mut ssh_child: Option<Child> = None;
        let db_url = if let Some(ref url) = self.config.database_url {
            url.clone()
        } else if let Some(ref ssh_host) = self.config.ssh_host {
            let local_port = pick_ephemeral_loopback_port()?;
            let forward_spec = format!(
                "127.0.0.1:{local_port}:127.0.0.1:{}",
                self.config.ssh_remote_port
            );
            let child = Command::new("ssh")
                .args([
                    "-N",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "ExitOnForwardFailure=yes",
                    "-o",
                    "ServerAliveInterval=30",
                    "-o",
                    "ServerAliveCountMax=3",
                    "-L",
                    &forward_spec,
                    ssh_host,
                ])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped())
                .kill_on_drop(true)
                .spawn()
                .with_context(|| format!("Failed to spawn ssh tunnel to {ssh_host}"))?;
            ssh_child = Some(child);

            wait_for_local_port(local_port, Duration::from_secs(6)).await?;
            format!(
                "postgres://{}:{}@127.0.0.1:{local_port}/{}",
                urlencoding_simple(&self.config.db_user),
                urlencoding_simple(&self.config.db_password),
                urlencoding_simple(&self.config.db_name)
            )
        } else {
            bail!(
                "Neither DATABASE_URL nor PATRIMONIO_SSH_HOST is configured. \
                 Configure ~/.config/patrimonio-mcp/config.env or set DATABASE_URL."
            );
        };

        // Defense-in-depth: enforce read-only transaction mode and strict
        // statement/lock timeouts on every pooled connection even if the caller
        // connected with a non-restricted role in local dev.
        let pool = PgPoolOptions::new()
            .max_connections(3)
            .acquire_timeout(Duration::from_secs(8))
            .after_connect(|conn, _meta| {
                Box::pin(async move {
                    conn.execute(
                        "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY; \
                         SET statement_timeout = '10s'; \
                         SET lock_timeout = '2s';",
                    )
                    .await?;
                    Ok(())
                })
            })
            .connect(&db_url)
            .await
            .context("Failed to connect to Patrimonio PostgreSQL database")?;

        let user_id = match self.config.user_id {
            Some(uid) => uid,
            None => {
                let rows = sqlx::query(
                    "SELECT id FROM users WHERE is_active = true ORDER BY created_at ASC LIMIT 2",
                )
                .fetch_all(&pool)
                .await
                .context("Failed to resolve active user_id from users table")?;
                if rows.len() == 1 {
                    rows.first()
                        .and_then(|r| r.try_get::<Uuid, _>("id").ok())
                        .ok_or_else(|| anyhow!("Failed to read user id column"))?
                } else {
                    bail!(
                        "Multiple or zero active users found ({}); set PATRIMONIO_MCP_USER_ID explicitly.",
                        rows.len()
                    );
                }
            }
        };

        Ok(DbRuntime {
            pool,
            user_id,
            _ssh_tunnel: ssh_child,
        })
    }

    fn append_audit_log(&self, tool: &str, args: &Value, outcome: &str) {
        let entry = json!({
            "timestamp": Utc::now().to_rfc3339(),
            "tool": tool,
            "args": args,
            "outcome": outcome,
        });
        if let Some(parent) = self.config.audit_log_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(mut f) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.config.audit_log_path)
        {
            let _ = writeln!(f, "{entry}");
        }
    }
}

fn pick_ephemeral_loopback_port() -> Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .context("Failed to bind ephemeral loopback port for SSH tunnel")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

async fn wait_for_local_port(port: u16, timeout: Duration) -> Result<()> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .is_ok()
        {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("Timed out waiting for SSH port forward on 127.0.0.1:{port}");
        }
        tokio::time::sleep(Duration::from_millis(80)).await;
    }
}

fn urlencoding_simple(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn dec_to_f64(d: Decimal) -> f64 {
    d.round_dp(2).to_string().parse::<f64>().unwrap_or(0.0)
}

// =============================================================================
// MCP JSON-RPC 2.0 Types & Tool Metadata
// =============================================================================

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    #[allow(dead_code)]
    jsonrpc: Option<String>,
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct JsonRpcResponse {
    jsonrpc: &'static str,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
}

fn tool_definitions(allow_writes: bool) -> Vec<Value> {
    let read_only_annotations = json!({
        "readOnlyHint": true,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false
    });

    let mut tools = vec![
        json!({
            "name": "get_net_worth_summary",
            "title": "Get Net Worth Summary",
            "description": "Returns current Patrimonio net worth in USD and MXN, live USD/MXN FX rate with staleness indicator, asset/liability breakdown by currency, account type breakdown, institution breakdown, and active vs archived account counts. Enforces per-row USD conversion for MXN balances.",
            "inputSchema": {
                "type": "object",
                "properties": {},
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
        json!({
            "name": "get_net_worth_history_and_movers",
            "title": "Get Net Worth History & Attribution Movers",
            "description": "Computes daily net worth between start_date and end_date using Patrimonio's carry-forward snapshot algorithm (never naive per-date GROUP BY, so infrequently-synced accounts are never dropped) and ranks the top per-account USD gainers and losers over the window.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "start_date": {
                        "type": "string",
                        "description": "Window start date in YYYY-MM-DD format (defaults to 30 days ago)."
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Window end date in YYYY-MM-DD format (defaults to today UTC)."
                    },
                    "top_n": {
                        "type": "integer",
                        "description": "Maximum number of top movers to return (1..=50, default 10).",
                        "minimum": 1,
                        "maximum": 50
                    }
                },
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
        json!({
            "name": "list_accounts_and_sync_health",
            "title": "List Accounts & Institution Sync Health",
            "description": "Lists all accounts (active and optionally archived) with their institution's integration_type (plaid vs manual), sync_status (synced, reconnect_required, manual, etc.), last_synced_at, last_sync_error, latest transaction date, and actionable health status (e.g. plaid_reconnect_required, manual_import_stale, archived).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "include_archived": {
                        "type": "boolean",
                        "description": "Include archived accounts (default true)."
                    },
                    "only_issues": {
                        "type": "boolean",
                        "description": "If true, only return accounts that need attention (reconnect_required, stale manual import >35 days, NULL balance, or archived)."
                    },
                    "institution_filter": {
                        "type": "string",
                        "description": "Optional case-insensitive substring filter on institution name."
                    }
                },
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
        json!({
            "name": "search_transactions",
            "title": "Search Transactions",
            "description": "Parameterized search across transactions with per-row USD conversion (via USD_MXN_ROW_RATE_SQL). Supports filtering by text query (description, merchant, counterparty, notes), account_id, institution_name, category, and date/amount bounds. Limit is clamped to 1..=200.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Case-insensitive substring match against description, user_description, merchant_name, counterparty_name, or user_notes."
                    },
                    "account_id": {
                        "type": "string",
                        "description": "Optional account UUID filter."
                    },
                    "institution_name": {
                        "type": "string",
                        "description": "Optional case-insensitive substring match on institution name."
                    },
                    "category": {
                        "type": "string",
                        "description": "Optional case-insensitive match on effective category (COALESCE(user_category, category))."
                    },
                    "start_date": {
                        "type": "string",
                        "description": "Optional inclusive start date (YYYY-MM-DD)."
                    },
                    "end_date": {
                        "type": "string",
                        "description": "Optional inclusive end date (YYYY-MM-DD)."
                    },
                    "min_amount": {
                        "type": "number",
                        "description": "Optional minimum native amount."
                    },
                    "max_amount": {
                        "type": "number",
                        "description": "Optional maximum native amount."
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum rows to return (1..=200, default 50).",
                        "minimum": 1,
                        "maximum": 200
                    }
                },
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
        json!({
            "name": "get_holdings_and_lots",
            "title": "Get Investment Holdings & Tax Lots",
            "description": "Returns active investment holdings (symbol, name, quantity, price, market value, cost basis, unrealized P&L, last price update) across brokerage, stock plan, 401(k), IRA, HSA, and crypto accounts, with optional tax lot breakdown.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "account_id": {
                        "type": "string",
                        "description": "Optional account UUID filter."
                    },
                    "symbol": {
                        "type": "string",
                        "description": "Optional ticker symbol filter (case-insensitive)."
                    },
                    "include_lots": {
                        "type": "boolean",
                        "description": "If true, include holding_lots rows for each returned holding (default false)."
                    }
                },
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
        json!({
            "name": "get_loans_and_payments",
            "title": "Get Loans & Repayment Schedules",
            "description": "Lists loans with borrower info, principal, interest rate, status, and full loan_payments installment schedules. Automatically detects schedule anomalies such as future-dated installments marked paid while earlier installments remain scheduled/late.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "loan_id": {
                        "type": "string",
                        "description": "Optional loan UUID filter."
                    },
                    "borrower_query": {
                        "type": "string",
                        "description": "Optional case-insensitive substring filter on borrower_name or person name."
                    },
                    "status": {
                        "type": "string",
                        "description": "Optional loan status filter (active, paid_off, written_off, cancelled, defaulted)."
                    }
                },
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
        json!({
            "name": "audit_data_health",
            "title": "Audit Patrimonio Data Health & Anomalies",
            "description": "Runs a comprehensive read-only diagnostic across Patrimonio: checks for Plaid items needing re-login (reconnect_required), stale manual statement imports (>35 days), active accounts with NULL balances or missing recent balance_snapshots, loan repayment schedule anomalies, and unread user notifications.",
            "inputSchema": {
                "type": "object",
                "properties": {},
                "additionalProperties": false
            },
            "annotations": read_only_annotations
        }),
    ];

    tools.push(json!({
        "name": "reconcile_loan_installment",
        "title": "Reconcile Loan Installment (Dry-Run by Default)",
        "description": format!(
            "Updates or previews a loan_payments installment status (scheduled, paid, partial, late, skipped). \
             Defaults to dry_run=true (read-only preview of before/after state). \
             Executing with dry_run=false requires PATRIMONIO_MCP_ALLOW_WRITES=true (currently: {}) \
             and logs to the MCP audit log.",
            allow_writes
        ),
        "inputSchema": {
            "type": "object",
            "required": ["loan_id", "installment_number", "status", "reason"],
            "properties": {
                "loan_id": {
                    "type": "string",
                    "description": "UUID of the loan."
                },
                "installment_number": {
                    "type": "integer",
                    "description": "1-based installment number on the loan schedule.",
                    "minimum": 1
                },
                "status": {
                    "type": "string",
                    "enum": ["scheduled", "paid", "partial", "late", "skipped"],
                    "description": "Target status for the installment."
                },
                "paid_amount": {
                    "type": ["number", "null"],
                    "description": "Paid amount in the loan's native currency (null when resetting to scheduled)."
                },
                "paid_date": {
                    "type": ["string", "null"],
                    "description": "Date paid in YYYY-MM-DD format (null when resetting to scheduled)."
                },
                "actual_tx_id": {
                    "type": ["string", "null"],
                    "description": "Optional linked transaction UUID."
                },
                "reason": {
                    "type": "string",
                    "description": "Required human-readable explanation recorded in the audit log."
                },
                "dry_run": {
                    "type": "boolean",
                    "description": "If true (default), only preview the before/after change without mutating the database.",
                    "default": true
                }
            },
            "additionalProperties": false
        },
        "annotations": {
            "readOnlyHint": false,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false
        }
    }));

    tools
}

fn resource_definitions() -> Vec<Value> {
    vec![
        json!({
            "uri": "patrimonio://schema/invariants",
            "name": "Patrimonio Domain & Security Invariants",
            "description": "Core financial math rules (carry-forward snapshots, per-row USD/MXN FX conversion, liability sign handling, loan installment ordering) and least-privilege DB boundaries.",
            "mimeType": "text/markdown"
        }),
        json!({
            "uri": "patrimonio://health/live",
            "name": "Patrimonio Live Health Snapshot",
            "description": "Live summary of institution sync statuses, FX rate freshness, and active account snapshot coverage.",
            "mimeType": "application/json"
        }),
    ]
}

fn prompt_definitions() -> Vec<Value> {
    vec![
        json!({
            "name": "diagnose-net-worth-change",
            "description": "Investigate why net worth changed between two dates, separating market price moves, FX changes, and snapshot/sync issues.",
            "arguments": [
                {
                    "name": "start_date",
                    "description": "Start date (YYYY-MM-DD)",
                    "required": false
                },
                {
                    "name": "end_date",
                    "description": "End date (YYYY-MM-DD)",
                    "required": false
                }
            ]
        }),
        json!({
            "name": "triage-accounts-and-sync",
            "description": "Check which accounts were archived, which Plaid institutions need re-authentication (Link update mode), and which manual institutions need PDF/CSV statement imports.",
            "arguments": []
        }),
        json!({
            "name": "audit-loan-repayments",
            "description": "Inspect a borrower's loan schedule and match installments against bank transactions.",
            "arguments": [
                {
                    "name": "borrower",
                    "description": "Borrower name to inspect",
                    "required": true
                }
            ]
        }),
    ]
}

// =============================================================================
// Tool Implementations
// =============================================================================

async fn tool_get_net_worth_summary(rt: &DbRuntime) -> Result<Value> {
    let fx_rate = latest_usd_mxn_rate_for_write(&rt.pool).await;
    let fx_meta_row = sqlx::query(
        r#"
        SELECT rate, source, recorded_at
        FROM exchange_rates
        WHERE base_currency = 'USD' AND target_currency = 'MXN' AND rate > 0
        ORDER BY (source = 'manual') DESC, recorded_at DESC
        LIMIT 1
        "#,
    )
    .fetch_optional(&rt.pool)
    .await?;

    let (fx_recorded_at, fx_source, fx_stale) = match fx_meta_row {
        Some(r) => {
            let rec: Option<chrono::DateTime<Utc>> = r.try_get("recorded_at").ok();
            let src: String = r
                .try_get("source")
                .unwrap_or_else(|_| "unknown".to_string());
            let stale = rec.is_none_or(|ts| (Utc::now() - ts).num_days() > 7);
            (rec.map(|t| t.to_rfc3339()), src, stale)
        }
        None => (None, "fallback_20.0".to_string(), true),
    };

    let currency_rows = sqlx::query(
        r#"
        SELECT currency,
               COUNT(*) AS account_count,
               COALESCE(SUM(CASE WHEN NOT is_liability_account_type(account_type)
                                 THEN COALESCE(current_balance, 0) ELSE 0 END), 0) AS assets,
               COALESCE(SUM(CASE WHEN is_liability_account_type(account_type)
                                 THEN ABS(COALESCE(current_balance, 0)) ELSE 0 END), 0) AS liabilities
        FROM accounts
        WHERE user_id = $1 AND archived_at IS NULL
        GROUP BY currency
        ORDER BY currency
        "#,
    )
    .bind(rt.user_id)
    .fetch_all(&rt.pool)
    .await?;

    let mut total_assets_usd = Decimal::ZERO;
    let mut total_liabilities_usd = Decimal::ZERO;
    let mut by_currency = Vec::new();

    for r in &currency_rows {
        let currency: String = r.try_get("currency")?;
        let count: i64 = r.try_get("account_count")?;
        let assets: Decimal = r.try_get("assets")?;
        let liabilities: Decimal = r.try_get("liabilities")?;
        let net = assets - liabilities;
        let to_usd = |amt: Decimal| -> Decimal {
            if currency.eq_ignore_ascii_case("MXN") {
                amt / fx_rate
            } else {
                amt
            }
        };
        let assets_usd = to_usd(assets);
        let liabilities_usd = to_usd(liabilities);
        total_assets_usd += assets_usd;
        total_liabilities_usd += liabilities_usd;

        by_currency.push(json!({
            "currency": currency,
            "active_accounts": count,
            "assets_native": dec_to_f64(assets),
            "liabilities_native": dec_to_f64(liabilities),
            "net_native": dec_to_f64(net),
            "net_usd": dec_to_f64(assets_usd - liabilities_usd)
        }));
    }

    let net_worth_usd = total_assets_usd - total_liabilities_usd;
    let net_worth_mxn = net_worth_usd * fx_rate;

    let inst_rows = sqlx::query(
        r#"
        SELECT i.name AS institution_name,
               i.country,
               i.integration_type,
               i.sync_status,
               COUNT(*) AS account_count,
               COALESCE(SUM(
                   CASE WHEN is_liability_account_type(a.account_type)
                        THEN -ABS(COALESCE(a.current_balance, 0))
                        ELSE COALESCE(a.current_balance, 0)
                   END
                   / CASE WHEN a.currency = 'MXN' THEN $1::numeric ELSE 1::numeric END
               ), 0) AS net_usd
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.user_id = $2 AND a.archived_at IS NULL
        GROUP BY i.name, i.country, i.integration_type, i.sync_status
        ORDER BY net_usd DESC
        "#,
    )
    .bind(fx_rate)
    .bind(rt.user_id)
    .fetch_all(&rt.pool)
    .await?;

    let by_institution: Vec<Value> = inst_rows
        .iter()
        .map(|r| {
            let net_usd: Decimal = r.try_get("net_usd").unwrap_or(Decimal::ZERO);
            json!({
                "institution": r.try_get::<String, _>("institution_name").unwrap_or_default(),
                "country": r.try_get::<String, _>("country").unwrap_or_default(),
                "integration_type": r.try_get::<String, _>("integration_type").unwrap_or_default(),
                "sync_status": r.try_get::<String, _>("sync_status").unwrap_or_default(),
                "active_accounts": r.try_get::<i64, _>("account_count").unwrap_or(0),
                "net_usd": dec_to_f64(net_usd)
            })
        })
        .collect();

    let archived_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM accounts WHERE user_id = $1 AND archived_at IS NOT NULL",
    )
    .bind(rt.user_id)
    .fetch_one(&rt.pool)
    .await?;

    let active_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM accounts WHERE user_id = $1 AND archived_at IS NULL",
    )
    .bind(rt.user_id)
    .fetch_one(&rt.pool)
    .await?;

    Ok(json!({
        "net_worth_usd": dec_to_f64(net_worth_usd),
        "net_worth_mxn": dec_to_f64(net_worth_mxn),
        "total_assets_usd": dec_to_f64(total_assets_usd),
        "total_liabilities_usd": dec_to_f64(total_liabilities_usd),
        "fx_usd_mxn": {
            "rate": dec_to_f64(fx_rate),
            "source": fx_source,
            "recorded_at": fx_recorded_at,
            "stale": fx_stale
        },
        "account_counts": {
            "active": active_count,
            "archived": archived_count
        },
        "by_currency": by_currency,
        "by_institution": by_institution
    }))
}

async fn tool_get_net_worth_history_and_movers(rt: &DbRuntime, args: &Value) -> Result<Value> {
    let today = Utc::now().date_naive();
    let end_date = match args.get("end_date").and_then(Value::as_str) {
        Some(s) => NaiveDate::parse_from_str(s, "%Y-%m-%d")
            .with_context(|| format!("Invalid end_date '{s}' (expected YYYY-MM-DD)"))?,
        None => today,
    };
    let start_date = match args.get("start_date").and_then(Value::as_str) {
        Some(s) => NaiveDate::parse_from_str(s, "%Y-%m-%d")
            .with_context(|| format!("Invalid start_date '{s}' (expected YYYY-MM-DD)"))?,
        None => end_date - chrono::Duration::days(30),
    };
    if start_date > end_date {
        bail!("start_date ({start_date}) must be on or before end_date ({end_date})");
    }
    let top_n = args
        .get("top_n")
        .and_then(Value::as_u64)
        .unwrap_or(10)
        .clamp(1, 50);

    // Fetch active accounts metadata + seed state on or before start_date so
    // carry-forward starts with every existing account's known balance as of
    // `start_date`, matching `dashboard.rs::net_worth_history`.
    let acct_rows = sqlx::query(
        r#"
        SELECT a.id, a.name, a.account_type, a.currency,
               is_liability_account_type(a.account_type) AS is_liability,
               i.name AS institution_name
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.user_id = $1 AND a.archived_at IS NULL
        "#,
    )
    .bind(rt.user_id)
    .fetch_all(&rt.pool)
    .await?;

    #[derive(Clone)]
    struct AcctMeta {
        name: String,
        institution: String,
        account_type: String,
        currency: String,
        is_liability: bool,
    }

    let mut metas: HashMap<Uuid, AcctMeta> = HashMap::new();
    for r in &acct_rows {
        let id: Uuid = r.try_get("id")?;
        metas.insert(
            id,
            AcctMeta {
                name: r.try_get("name")?,
                institution: r.try_get("institution_name")?,
                account_type: r.try_get("account_type")?,
                currency: r.try_get("currency")?,
                is_liability: r.try_get("is_liability")?,
            },
        );
    }

    // Seed each active account with its latest snapshot on-or-before start_date,
    // plus pull all snapshots in [start_date, end_date] ordered by (as_of_date ASC, id ASC).
    let seed_rows = sqlx::query(
        r#"
        SELECT DISTINCT ON (bs.account_id)
               bs.account_id, bs.as_of_date, bs.balance, COALESCE(bs.balance_usd, bs.balance) AS balance_usd
        FROM balance_snapshots bs
        JOIN accounts a ON a.id = bs.account_id
        WHERE bs.user_id = $1
          AND a.archived_at IS NULL
          AND bs.as_of_date <= $2
        ORDER BY bs.account_id, bs.as_of_date DESC, bs.id DESC
        "#,
    )
    .bind(rt.user_id)
    .bind(start_date)
    .fetch_all(&rt.pool)
    .await?;

    #[derive(Clone, Copy)]
    struct SnapVal {
        native: Decimal,
        usd: Decimal,
    }

    let mut carried: HashMap<Uuid, SnapVal> = HashMap::new();
    for r in &seed_rows {
        let account_id: Uuid = r.try_get("account_id")?;
        carried.insert(
            account_id,
            SnapVal {
                native: r.try_get("balance")?,
                usd: r.try_get("balance_usd")?,
            },
        );
    }

    let window_rows = sqlx::query(
        r#"
        SELECT bs.account_id, bs.as_of_date, bs.balance, COALESCE(bs.balance_usd, bs.balance) AS balance_usd
        FROM balance_snapshots bs
        JOIN accounts a ON a.id = bs.account_id
        WHERE bs.user_id = $1
          AND a.archived_at IS NULL
          AND bs.as_of_date >= $2
          AND bs.as_of_date <= $3
        ORDER BY bs.as_of_date ASC, bs.id ASC
        "#,
    )
    .bind(rt.user_id)
    .bind(start_date)
    .bind(end_date)
    .fetch_all(&rt.pool)
    .await?;

    let mut by_date: BTreeMap<NaiveDate, Vec<(Uuid, SnapVal)>> = BTreeMap::new();
    for r in &window_rows {
        let dt: NaiveDate = r.try_get("as_of_date")?;
        let account_id: Uuid = r.try_get("account_id")?;
        by_date.entry(dt).or_default().push((
            account_id,
            SnapVal {
                native: r.try_get("balance")?,
                usd: r.try_get("balance_usd")?,
            },
        ));
    }

    let signed_usd = |acct_id: &Uuid, val: &SnapVal| -> Decimal {
        let is_liab = metas.get(acct_id).is_some_and(|m| m.is_liability);
        if is_liab {
            -val.usd.abs()
        } else {
            val.usd
        }
    };

    let mut start_state: Option<HashMap<Uuid, SnapVal>> = None;
    let mut series = Vec::new();

    for (dt, updates) in &by_date {
        let raw_row_count = updates.len();
        for (acct_id, val) in updates {
            carried.insert(*acct_id, *val);
        }
        if start_state.is_none() {
            start_state = Some(carried.clone());
        }
        let total_usd: Decimal = carried
            .iter()
            .map(|(acct_id, val)| signed_usd(acct_id, val))
            .sum();
        series.push(json!({
            "date": dt.to_string(),
            "net_worth_usd": dec_to_f64(total_usd),
            "carried_accounts": carried.len(),
            "snapshots_written_on_date": raw_row_count
        }));
    }

    let start_map = start_state.unwrap_or_default();
    let end_map = carried;

    let start_nw: Decimal = start_map.iter().map(|(id, v)| signed_usd(id, v)).sum();
    let end_nw: Decimal = end_map.iter().map(|(id, v)| signed_usd(id, v)).sum();
    let delta_nw = end_nw - start_nw;

    let mut movers: Vec<(Decimal, Value)> = Vec::new();
    for (acct_id, meta) in &metas {
        let s = start_map.get(acct_id).copied().unwrap_or(SnapVal {
            native: Decimal::ZERO,
            usd: Decimal::ZERO,
        });
        let e = end_map.get(acct_id).copied().unwrap_or(SnapVal {
            native: Decimal::ZERO,
            usd: Decimal::ZERO,
        });
        let s_signed = signed_usd(acct_id, &s);
        let e_signed = signed_usd(acct_id, &e);
        let diff_usd = e_signed - s_signed;
        let diff_native = e.native - s.native;

        if diff_usd != Decimal::ZERO || diff_native != Decimal::ZERO {
            movers.push((
                diff_usd.abs(),
                json!({
                    "account_id": acct_id.to_string(),
                    "institution": meta.institution,
                    "account_name": meta.name,
                    "account_type": meta.account_type,
                    "currency": meta.currency,
                    "is_liability": meta.is_liability,
                    "start_native": dec_to_f64(s.native),
                    "end_native": dec_to_f64(e.native),
                    "delta_native": dec_to_f64(diff_native),
                    "start_net_usd": dec_to_f64(s_signed),
                    "end_net_usd": dec_to_f64(e_signed),
                    "delta_net_usd": dec_to_f64(diff_usd)
                }),
            ));
        }
    }

    movers.sort_by_key(|b| std::cmp::Reverse(b.0));
    let top_movers: Vec<Value> = movers
        .into_iter()
        .take(usize::try_from(top_n).unwrap_or(10))
        .map(|(_, v)| v)
        .collect();

    Ok(json!({
        "window": {
            "start_date": start_date.to_string(),
            "end_date": end_date.to_string()
        },
        "start_net_worth_usd": dec_to_f64(start_nw),
        "end_net_worth_usd": dec_to_f64(end_nw),
        "net_worth_delta_usd": dec_to_f64(delta_nw),
        "top_movers_by_abs_usd_change": top_movers,
        "daily_series": series
    }))
}

async fn tool_list_accounts_and_sync_health(rt: &DbRuntime, args: &Value) -> Result<Value> {
    let include_archived = args
        .get("include_archived")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let only_issues = args
        .get("only_issues")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let institution_filter = args
        .get("institution_filter")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let fx_rate = latest_usd_mxn_rate_for_write(&rt.pool).await;
    let rows = sqlx::query(
        r#"
        SELECT a.id,
               a.name AS account_name,
               a.nickname,
               a.account_type,
               a.currency,
               a.current_balance,
               a.available_balance,
               a.archived_at,
               a.updated_at,
               i.id AS institution_id,
               i.name AS institution_name,
               i.country,
               i.integration_type,
               i.sync_status,
               i.last_synced_at,
               i.last_sync_error,
               (SELECT MAX(t.date) FROM transactions t WHERE t.account_id = a.id AND t.user_id = $1) AS latest_tx_date,
               (SELECT MAX(bs.as_of_date) FROM balance_snapshots bs WHERE bs.account_id = a.id AND bs.user_id = $1) AS latest_snapshot_date
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.user_id = $1
          AND ($2::boolean OR a.archived_at IS NULL)
          AND ($3::text IS NULL OR i.name ILIKE '%' || $3 || '%')
        ORDER BY a.archived_at NULLS FIRST, i.name ASC, a.name ASC
        "#,
    )
    .bind(rt.user_id)
    .bind(include_archived)
    .bind(institution_filter)
    .fetch_all(&rt.pool)
    .await?;

    let now = Utc::now();
    let mut accounts_out = Vec::new();

    for r in &rows {
        let id: Uuid = r.try_get("id")?;
        let account_name: String = r.try_get("account_name")?;
        let nickname: Option<String> = r.try_get("nickname").ok().flatten();
        let account_type: String = r.try_get("account_type")?;
        let currency: String = r.try_get("currency")?;
        let current_balance: Option<Decimal> = r.try_get("current_balance").ok().flatten();
        let archived_at: Option<chrono::DateTime<Utc>> = r.try_get("archived_at").ok().flatten();
        let updated_at: Option<chrono::DateTime<Utc>> = r.try_get("updated_at").ok().flatten();
        let institution_id: Uuid = r.try_get("institution_id")?;
        let institution_name: String = r.try_get("institution_name")?;
        let country: String = r.try_get("country")?;
        let integration_type: String = r.try_get("integration_type")?;
        let sync_status: String = r
            .try_get::<Option<String>, _>("sync_status")
            .ok()
            .flatten()
            .unwrap_or_else(|| "unknown".to_string());
        let last_synced_at: Option<chrono::DateTime<Utc>> =
            r.try_get("last_synced_at").ok().flatten();
        let last_sync_error: Option<String> = r.try_get("last_sync_error").ok().flatten();
        let latest_tx_date: Option<NaiveDate> = r.try_get("latest_tx_date").ok().flatten();
        let latest_snapshot_date: Option<NaiveDate> =
            r.try_get("latest_snapshot_date").ok().flatten();

        let days_since_update = updated_at.map(|u| (now - u).num_days());
        let (health_status, recommended_action) = if archived_at.is_some() {
            (
                "archived",
                "Account is archived (excluded from active net worth and daily snapshots). No action needed unless archived by mistake.",
            )
        } else if current_balance.is_none() {
            (
                "null_balance_warning",
                "Active account has NULL current_balance; set balance to 0.00 or sync to prevent snapshot issues.",
            )
        } else if integration_type == "plaid" && sync_status == "reconnect_required" {
            (
                "plaid_reconnect_required",
                "Use 'Reconnect' (Plaid Link update mode) in Settings -> Institutions. Do NOT delete and re-add the institution, or historical linkage will be lost.",
            )
        } else if integration_type == "plaid" && sync_status != "synced" {
            (
                "plaid_sync_issue",
                "Check institution sync status and trigger a manual sync or reconnect in Settings.",
            )
        } else if integration_type == "manual" && days_since_update.is_some_and(|d| d > 35) {
            (
                "manual_import_stale",
                "Manual account has not been updated in >35 days; upload latest PDF/CSV statement in Imports or update balance.",
            )
        } else {
            ("healthy", "None")
        };

        if only_issues && health_status == "healthy" {
            continue;
        }

        let bal = current_balance.unwrap_or(Decimal::ZERO);
        let bal_usd = if currency.eq_ignore_ascii_case("MXN") {
            bal / fx_rate
        } else {
            bal
        };

        accounts_out.push(json!({
            "account_id": id.to_string(),
            "institution_id": institution_id.to_string(),
            "institution": institution_name,
            "country": country,
            "account_name": account_name,
            "nickname": nickname,
            "account_type": account_type,
            "currency": currency,
            "current_balance": current_balance.map(dec_to_f64),
            "current_balance_usd": dec_to_f64(bal_usd),
            "integration_type": integration_type,
            "sync_status": sync_status,
            "last_synced_at": last_synced_at.map(|t| t.to_rfc3339()),
            "last_sync_error": last_sync_error,
            "updated_at": updated_at.map(|t| t.to_rfc3339()),
            "days_since_update": days_since_update,
            "latest_tx_date": latest_tx_date.map(|d| d.to_string()),
            "latest_snapshot_date": latest_snapshot_date.map(|d| d.to_string()),
            "archived_at": archived_at.map(|t| t.to_rfc3339()),
            "health_status": health_status,
            "recommended_action": recommended_action
        }));
    }

    Ok(json!({
        "count": accounts_out.len(),
        "accounts": accounts_out
    }))
}

async fn tool_search_transactions(rt: &DbRuntime, args: &Value) -> Result<Value> {
    let query_str = args
        .get("query")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let account_id = match args
        .get("account_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(s) => {
            Some(Uuid::parse_str(s).with_context(|| format!("Invalid account_id UUID: {s}"))?)
        }
        None => None,
    };
    let institution_name = args
        .get("institution_name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let category = args
        .get("category")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let start_date = match args
        .get("start_date")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(s) => Some(
            NaiveDate::parse_from_str(s, "%Y-%m-%d")
                .with_context(|| format!("Invalid start_date: {s}"))?,
        ),
        None => None,
    };
    let end_date = match args
        .get("end_date")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(s) => Some(
            NaiveDate::parse_from_str(s, "%Y-%m-%d")
                .with_context(|| format!("Invalid end_date: {s}"))?,
        ),
        None => None,
    };
    let min_amount = match args.get("min_amount").and_then(Value::as_f64) {
        Some(v) => {
            Some(Decimal::try_from(v).with_context(|| format!("Invalid min_amount decimal: {v}"))?)
        }
        None => None,
    };
    let max_amount = match args.get("max_amount").and_then(Value::as_f64) {
        Some(v) => {
            Some(Decimal::try_from(v).with_context(|| format!("Invalid max_amount decimal: {v}"))?)
        }
        None => None,
    };
    let limit = args
        .get("limit")
        .and_then(Value::as_i64)
        .unwrap_or(DEFAULT_SEARCH_LIMIT)
        .clamp(1, MAX_SEARCH_LIMIT);

    // Compose only the static shared FX SQL constants from `services/fx.rs`;
    // every caller-supplied filter is a positional `.bind()`.
    let sql = format!(
        r#"
        SELECT t.id,
               t.date,
               a.id AS account_id,
               a.name AS account_name,
               i.name AS institution_name,
               COALESCE(t.user_description, t.description) AS effective_description,
               t.description AS raw_description,
               t.merchant_name,
               t.counterparty_name,
               COALESCE(t.user_category, t.category) AS effective_category,
               t.amount,
               t.currency,
               ROUND(({AMOUNT_USD_SQL})::numeric, 2) AS amount_usd,
               t.pending,
               t.source,
               t.user_notes
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.user_id = $1
          AND ($2::uuid IS NULL OR t.account_id = $2)
          AND ($3::text IS NULL OR i.name ILIKE '%' || $3 || '%')
          AND ($4::text IS NULL OR COALESCE(t.user_category, t.category, '') ILIKE '%' || $4 || '%')
          AND ($5::date IS NULL OR t.date >= $5)
          AND ($6::date IS NULL OR t.date <= $6)
          AND ($7::numeric IS NULL OR t.amount >= $7)
          AND ($8::numeric IS NULL OR t.amount <= $8)
          AND (
              $9::text IS NULL
              OR t.description ILIKE '%' || $9 || '%'
              OR COALESCE(t.user_description, '') ILIKE '%' || $9 || '%'
              OR COALESCE(t.merchant_name, '') ILIKE '%' || $9 || '%'
              OR COALESCE(t.counterparty_name, '') ILIKE '%' || $9 || '%'
              OR COALESCE(t.user_notes, '') ILIKE '%' || $9 || '%'
          )
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $10
        "#,
    );

    let rows = sqlx::query(&sql)
        .bind(rt.user_id)
        .bind(account_id)
        .bind(institution_name)
        .bind(category)
        .bind(start_date)
        .bind(end_date)
        .bind(min_amount)
        .bind(max_amount)
        .bind(query_str)
        .bind(limit)
        .fetch_all(&rt.pool)
        .await?;

    let txs: Vec<Value> = rows
        .iter()
        .map(|r| {
            let amount: Decimal = r.try_get("amount").unwrap_or(Decimal::ZERO);
            let amount_usd: Decimal = r.try_get("amount_usd").unwrap_or(Decimal::ZERO);
            json!({
                "id": r.try_get::<Uuid, _>("id").map(|u| u.to_string()).unwrap_or_default(),
                "date": r.try_get::<NaiveDate, _>("date").map(|d| d.to_string()).unwrap_or_default(),
                "institution": r.try_get::<String, _>("institution_name").unwrap_or_default(),
                "account_id": r.try_get::<Uuid, _>("account_id").map(|u| u.to_string()).unwrap_or_default(),
                "account_name": r.try_get::<String, _>("account_name").unwrap_or_default(),
                "description": r.try_get::<String, _>("effective_description").unwrap_or_default(),
                "raw_description": r.try_get::<String, _>("raw_description").unwrap_or_default(),
                "merchant_name": r.try_get::<Option<String>, _>("merchant_name").ok().flatten(),
                "counterparty_name": r.try_get::<Option<String>, _>("counterparty_name").ok().flatten(),
                "category": r.try_get::<Option<String>, _>("effective_category").ok().flatten(),
                "amount": dec_to_f64(amount),
                "currency": r.try_get::<String, _>("currency").unwrap_or_default(),
                "amount_usd": dec_to_f64(amount_usd),
                "pending": r.try_get::<Option<bool>, _>("pending").ok().flatten().unwrap_or(false),
                "source": r.try_get::<Option<String>, _>("source").ok().flatten(),
                "notes": r.try_get::<Option<String>, _>("user_notes").ok().flatten()
            })
        })
        .collect();

    Ok(json!({
        "returned": txs.len(),
        "limit": limit,
        "transactions": txs
    }))
}

async fn tool_get_holdings_and_lots(rt: &DbRuntime, args: &Value) -> Result<Value> {
    let account_id = match args
        .get("account_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(s) => {
            Some(Uuid::parse_str(s).with_context(|| format!("Invalid account_id UUID: {s}"))?)
        }
        None => None,
    };
    let symbol = args
        .get("symbol")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let include_lots = args
        .get("include_lots")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let fx_rate = latest_usd_mxn_rate_for_write(&rt.pool).await;
    let rows = sqlx::query(
        r#"
        SELECT h.id,
               h.account_id,
               a.name AS account_name,
               i.name AS institution_name,
               h.symbol,
               h.name AS security_name,
               h.quantity,
               h.price,
               h.value,
               h.cost_basis,
               h.currency,
               h.holding_type,
               h.updated_at
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE h.user_id = $1
          AND h.deleted_at IS NULL
          AND a.archived_at IS NULL
          AND ($2::uuid IS NULL OR h.account_id = $2)
          AND ($3::text IS NULL OR UPPER(h.symbol) = UPPER($3))
        ORDER BY COALESCE(h.value, 0) DESC, h.symbol ASC
        "#,
    )
    .bind(rt.user_id)
    .bind(account_id)
    .bind(symbol)
    .fetch_all(&rt.pool)
    .await?;

    let mut lots_by_holding: HashMap<Uuid, Vec<Value>> = HashMap::new();
    if include_lots && !rows.is_empty() {
        let lot_rows = sqlx::query(
            r#"
            SELECT holding_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate
            FROM holding_lots
            WHERE user_id = $1
            ORDER BY acquired_at ASC
            "#,
        )
        .bind(rt.user_id)
        .fetch_all(&rt.pool)
        .await?;

        for lr in &lot_rows {
            let hid: Uuid = lr.try_get("holding_id")?;
            let qty: Decimal = lr.try_get("qty").unwrap_or(Decimal::ZERO);
            let cpu: Decimal = lr.try_get("cost_per_unit").unwrap_or(Decimal::ZERO);
            lots_by_holding.entry(hid).or_default().push(json!({
                "acquired_at": lr.try_get::<Option<NaiveDate>, _>("acquired_at").ok().flatten().map(|d| d.to_string()),
                "quantity": qty.to_string(),
                "cost_per_unit": dec_to_f64(cpu),
                "currency": lr.try_get::<String, _>("currency").unwrap_or_default()
            }));
        }
    }

    let mut total_value_usd = Decimal::ZERO;
    let holdings_out: Vec<Value> = rows
        .iter()
        .map(|r| {
            let id: Uuid = r.try_get("id").unwrap_or_default();
            let qty: Option<Decimal> = r.try_get("quantity").ok().flatten();
            let price: Option<Decimal> = r.try_get("price").ok().flatten();
            let val: Decimal = r.try_get::<Option<Decimal>, _>("value").ok().flatten().unwrap_or(Decimal::ZERO);
            let cost: Option<Decimal> = r.try_get("cost_basis").ok().flatten();
            let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
            let val_usd = if currency.eq_ignore_ascii_case("MXN") {
                val / fx_rate
            } else {
                val
            };
            total_value_usd += val_usd;
            let unrealized = cost.map(|c| val - c);
            let mut obj = json!({
                "holding_id": id.to_string(),
                "account_id": r.try_get::<Uuid, _>("account_id").map(|u| u.to_string()).unwrap_or_default(),
                "institution": r.try_get::<String, _>("institution_name").unwrap_or_default(),
                "account_name": r.try_get::<String, _>("account_name").unwrap_or_default(),
                "symbol": r.try_get::<String, _>("symbol").unwrap_or_default(),
                "security_name": r.try_get::<String, _>("security_name").unwrap_or_default(),
                "quantity": qty.map(|q| q.normalize().to_string()),
                "price": price.map(dec_to_f64),
                "value_native": dec_to_f64(val),
                "value_usd": dec_to_f64(val_usd),
                "cost_basis_native": cost.map(dec_to_f64),
                "unrealized_pnl_native": unrealized.map(dec_to_f64),
                "currency": currency,
                "holding_type": r.try_get::<Option<String>, _>("holding_type").ok().flatten(),
                "updated_at": r.try_get::<Option<chrono::DateTime<Utc>>, _>("updated_at").ok().flatten().map(|t| t.to_rfc3339())
            });
            if include_lots {
                if let Some(obj_map) = obj.as_object_mut() {
                    obj_map.insert(
                        "lots".to_string(),
                        json!(lots_by_holding.remove(&id).unwrap_or_default()),
                    );
                }
            }
            obj
        })
        .collect();

    Ok(json!({
        "count": holdings_out.len(),
        "total_value_usd": dec_to_f64(total_value_usd),
        "holdings": holdings_out
    }))
}

async fn tool_get_loans_and_payments(rt: &DbRuntime, args: &Value) -> Result<Value> {
    let loan_id = match args
        .get("loan_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(s) => Some(Uuid::parse_str(s).with_context(|| format!("Invalid loan_id UUID: {s}"))?),
        None => None,
    };
    let borrower_query = args
        .get("borrower_query")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let status_filter = args
        .get("status")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let loan_rows = sqlx::query(
        r#"
        SELECT l.id,
               l.person_id,
               p.name AS person_name,
               l.borrower_name,
               l.principal,
               l.currency,
               l.interest_rate,
               l.interest_type,
               l.rate_period,
               l.origination_date,
               l.term_months,
               l.payment_frequency,
               l.expected_repayment_date,
               l.status,
               l.notes
        FROM loans l
        LEFT JOIN people p ON l.person_id = p.id
        WHERE l.user_id = $1
          AND ($2::uuid IS NULL OR l.id = $2)
          AND ($3::text IS NULL OR l.borrower_name ILIKE '%' || $3 || '%' OR COALESCE(p.name, '') ILIKE '%' || $3 || '%')
          AND ($4::text IS NULL OR l.status = $4)
        ORDER BY l.origination_date DESC
        "#,
    )
    .bind(rt.user_id)
    .bind(loan_id)
    .bind(borrower_query)
    .bind(status_filter)
    .fetch_all(&rt.pool)
    .await?;

    let payment_rows = sqlx::query(
        r#"
        SELECT lp.id,
               lp.loan_id,
               lp.installment_number,
               lp.due_date,
               lp.scheduled_amount,
               lp.scheduled_principal,
               lp.scheduled_interest,
               lp.paid_amount,
               lp.paid_date,
               lp.status,
               lp.actual_tx_id,
               lp.balance_after
        FROM loan_payments lp
        WHERE lp.user_id = $1
        ORDER BY lp.loan_id, lp.installment_number ASC
        "#,
    )
    .bind(rt.user_id)
    .fetch_all(&rt.pool)
    .await?;

    let mut payments_by_loan: HashMap<Uuid, Vec<Value>> = HashMap::new();
    let mut anomalies_by_loan: HashMap<Uuid, Vec<String>> = HashMap::new();
    let today = Utc::now().date_naive();

    // Group raw payment rows by loan to inspect sequential consistency.
    let mut raw_by_loan: HashMap<Uuid, Vec<&sqlx::postgres::PgRow>> = HashMap::new();
    for pr in &payment_rows {
        let lid: Uuid = pr.try_get("loan_id")?;
        raw_by_loan.entry(lid).or_default().push(pr);
    }

    for (lid, rows) in raw_by_loan {
        let mut earliest_unpaid_installment: Option<i32> = None;
        for r in rows {
            let inst_num: i32 = r.try_get("installment_number")?;
            let due_date: Option<NaiveDate> = r.try_get("due_date").ok().flatten();
            let sched_amt: Decimal = r.try_get("scheduled_amount").unwrap_or(Decimal::ZERO);
            let paid_amt: Option<Decimal> = r.try_get("paid_amount").ok().flatten();
            let paid_date: Option<NaiveDate> = r.try_get("paid_date").ok().flatten();
            let status: String = r.try_get("status")?;
            let tx_id: Option<Uuid> = r.try_get("actual_tx_id").ok().flatten();
            let bal_after: Option<Decimal> = r.try_get("balance_after").ok().flatten();

            if status != "paid" && status != "skipped" && earliest_unpaid_installment.is_none() {
                earliest_unpaid_installment = Some(inst_num);
            }
            if status == "paid" {
                if let Some(unpaid_inst) = earliest_unpaid_installment {
                    if inst_num > unpaid_inst {
                        anomalies_by_loan.entry(lid).or_default().push(format!(
                            "Installment #{inst_num} (due {:?}) is marked 'paid' while earlier installment #{unpaid_inst} is still unpaid — out-of-order payment assignment.",
                            due_date.map(|d| d.to_string())
                        ));
                    }
                }
            }
            if (status == "scheduled" || status == "late") && due_date.is_some_and(|d| d < today) {
                anomalies_by_loan.entry(lid).or_default().push(format!(
                    "Installment #{inst_num} due on {} is past due (status: {status}).",
                    due_date.map(|d| d.to_string()).unwrap_or_default()
                ));
            }

            payments_by_loan.entry(lid).or_default().push(json!({
                "payment_id": r.try_get::<Uuid, _>("id").map(|u| u.to_string()).unwrap_or_default(),
                "installment_number": inst_num,
                "due_date": due_date.map(|d| d.to_string()),
                "scheduled_amount": dec_to_f64(sched_amt),
                "paid_amount": paid_amt.map(dec_to_f64),
                "paid_date": paid_date.map(|d| d.to_string()),
                "status": status,
                "actual_tx_id": tx_id.map(|u| u.to_string()),
                "balance_after": bal_after.map(dec_to_f64)
            }));
        }
    }

    let loans_out: Vec<Value> = loan_rows
        .iter()
        .map(|r| {
            let lid: Uuid = r.try_get("id").unwrap_or_default();
            let principal: Decimal = r.try_get("principal").unwrap_or(Decimal::ZERO);
            let rate: Decimal = r.try_get("interest_rate").unwrap_or(Decimal::ZERO);
            let payments = payments_by_loan.remove(&lid).unwrap_or_default();
            let anomalies = anomalies_by_loan.remove(&lid).unwrap_or_default();
            json!({
                "loan_id": lid.to_string(),
                "person_id": r.try_get::<Option<Uuid>, _>("person_id").ok().flatten().map(|u| u.to_string()),
                "borrower_name": r.try_get::<String, _>("borrower_name").unwrap_or_default(),
                "principal": dec_to_f64(principal),
                "currency": r.try_get::<String, _>("currency").unwrap_or_default(),
                "interest_rate": rate.normalize().to_string(),
                "interest_type": r.try_get::<String, _>("interest_type").unwrap_or_default(),
                "rate_period": r.try_get::<String, _>("rate_period").unwrap_or_default(),
                "origination_date": r.try_get::<NaiveDate, _>("origination_date").map(|d| d.to_string()).unwrap_or_default(),
                "term_months": r.try_get::<Option<i32>, _>("term_months").ok().flatten(),
                "payment_frequency": r.try_get::<Option<String>, _>("payment_frequency").ok().flatten(),
                "expected_repayment_date": r.try_get::<Option<NaiveDate>, _>("expected_repayment_date").ok().flatten().map(|d| d.to_string()),
                "status": r.try_get::<String, _>("status").unwrap_or_default(),
                "notes": r.try_get::<Option<String>, _>("notes").ok().flatten(),
                "schedule_anomalies": anomalies,
                "payments": payments
            })
        })
        .collect();

    Ok(json!({
        "count": loans_out.len(),
        "loans": loans_out
    }))
}

async fn tool_audit_data_health(rt: &DbRuntime) -> Result<Value> {
    let accounts_health = tool_list_accounts_and_sync_health(
        rt,
        &json!({
            "include_archived": true,
            "only_issues": true
        }),
    )
    .await?;

    let loans_data = tool_get_loans_and_payments(rt, &json!({ "status": "active" })).await?;
    let loan_anomalies: Vec<Value> = loans_data
        .get("loans")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter(|l| {
                    l.get("schedule_anomalies")
                        .and_then(Value::as_array)
                        .is_some_and(|a| !a.is_empty())
                })
                .map(|l| {
                    json!({
                        "loan_id": l.get("loan_id"),
                        "borrower_name": l.get("borrower_name"),
                        "anomalies": l.get("schedule_anomalies")
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    let unread_notifs = sqlx::query(
        r#"
        SELECT id, kind, title, body, created_at
        FROM user_notifications
        WHERE user_id = $1 AND read_at IS NULL
        ORDER BY created_at DESC
        LIMIT 25
        "#,
    )
    .bind(rt.user_id)
    .fetch_all(&rt.pool)
    .await?;

    let notifications: Vec<Value> = unread_notifs
        .iter()
        .map(|r| {
            json!({
                "id": r.try_get::<Uuid, _>("id").map(|u| u.to_string()).unwrap_or_default(),
                "kind": r.try_get::<String, _>("kind").unwrap_or_default(),
                "title": r.try_get::<String, _>("title").unwrap_or_default(),
                "body": r.try_get::<String, _>("body").unwrap_or_default(),
                "created_at": r.try_get::<chrono::DateTime<Utc>, _>("created_at").map(|t| t.to_rfc3339()).unwrap_or_default()
            })
        })
        .collect();

    Ok(json!({
        "checked_at": Utc::now().to_rfc3339(),
        "account_and_sync_issues": accounts_health.get("accounts").cloned().unwrap_or(json!([])),
        "loan_schedule_anomalies": loan_anomalies,
        "unread_notifications": notifications
    }))
}

async fn tool_reconcile_loan_installment(
    server: &McpServer,
    rt: &DbRuntime,
    args: &Value,
) -> Result<Value> {
    let loan_id_str = args
        .get("loan_id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Missing required parameter 'loan_id'"))?;
    let loan_id = Uuid::parse_str(loan_id_str)
        .with_context(|| format!("Invalid loan_id UUID: {loan_id_str}"))?;
    let installment_number = i32::try_from(
        args.get("installment_number")
            .and_then(Value::as_i64)
            .ok_or_else(|| anyhow!("Missing required parameter 'installment_number'"))?,
    )
    .context("installment_number out of range")?;
    let new_status = args
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Missing required parameter 'status'"))?;
    if !matches!(
        new_status,
        "scheduled" | "paid" | "partial" | "late" | "skipped"
    ) {
        bail!(
            "Invalid status '{new_status}'; must be one of scheduled, paid, partial, late, skipped"
        );
    }
    let reason = args
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("A non-empty 'reason' is required for audit logging"))?;
    let dry_run = args.get("dry_run").and_then(Value::as_bool).unwrap_or(true);

    let paid_amount: Option<Decimal> = match args.get("paid_amount") {
        Some(Value::Number(n)) => {
            let f = n.as_f64().ok_or_else(|| anyhow!("Invalid paid_amount"))?;
            Some(Decimal::try_from(f)?)
        }
        Some(Value::Null) | None => None,
        _ => bail!("paid_amount must be a number or null"),
    };

    let paid_date: Option<NaiveDate> = match args.get("paid_date") {
        Some(Value::String(s)) if !s.trim().is_empty() => Some(
            NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d")
                .with_context(|| format!("Invalid paid_date '{s}'"))?,
        ),
        Some(Value::Null) | Some(Value::String(_)) | None => None,
        _ => bail!("paid_date must be a YYYY-MM-DD string or null"),
    };

    let actual_tx_id: Option<Uuid> = match args.get("actual_tx_id") {
        Some(Value::String(s)) if !s.trim().is_empty() => Some(
            Uuid::parse_str(s.trim())
                .with_context(|| format!("Invalid actual_tx_id UUID '{s}'"))?,
        ),
        Some(Value::Null) | Some(Value::String(_)) | None => None,
        _ => bail!("actual_tx_id must be a UUID string or null"),
    };

    let current_row = sqlx::query(
        r#"
        SELECT lp.id, lp.status, lp.due_date, lp.scheduled_amount,
               lp.paid_amount, lp.paid_date, lp.actual_tx_id,
               l.borrower_name, l.currency
        FROM loan_payments lp
        JOIN loans l ON lp.loan_id = l.id
        WHERE lp.user_id = $1 AND lp.loan_id = $2 AND lp.installment_number = $3
        "#,
    )
    .bind(rt.user_id)
    .bind(loan_id)
    .bind(installment_number)
    .fetch_optional(&rt.pool)
    .await?
    .ok_or_else(|| {
        anyhow!("No loan_payments row found for loan_id={loan_id}, installment_number={installment_number}")
    })?;

    let before = json!({
        "payment_id": current_row.try_get::<Uuid, _>("id").map(|u| u.to_string()).unwrap_or_default(),
        "borrower_name": current_row.try_get::<String, _>("borrower_name").unwrap_or_default(),
        "currency": current_row.try_get::<String, _>("currency").unwrap_or_default(),
        "installment_number": installment_number,
        "due_date": current_row.try_get::<Option<NaiveDate>, _>("due_date").ok().flatten().map(|d| d.to_string()),
        "scheduled_amount": current_row.try_get::<Decimal, _>("scheduled_amount").map(dec_to_f64).unwrap_or(0.0),
        "status": current_row.try_get::<String, _>("status").unwrap_or_default(),
        "paid_amount": current_row.try_get::<Option<Decimal>, _>("paid_amount").ok().flatten().map(dec_to_f64),
        "paid_date": current_row.try_get::<Option<NaiveDate>, _>("paid_date").ok().flatten().map(|d| d.to_string()),
        "actual_tx_id": current_row.try_get::<Option<Uuid>, _>("actual_tx_id").ok().flatten().map(|u| u.to_string())
    });

    let after = json!({
        "installment_number": installment_number,
        "status": new_status,
        "paid_amount": paid_amount.map(dec_to_f64),
        "paid_date": paid_date.map(|d| d.to_string()),
        "actual_tx_id": actual_tx_id.map(|u| u.to_string()),
        "reason": reason
    });

    if dry_run {
        server.append_audit_log("reconcile_loan_installment", args, "dry_run_preview");
        return Ok(json!({
            "dry_run": true,
            "committed": false,
            "message": "Dry-run preview only. Review before/after state; to execute for real, PATRIMONIO_MCP_ALLOW_WRITES=true must be enabled and dry_run=false passed.",
            "before": before,
            "proposed_after": after
        }));
    }

    if !server.config.allow_writes {
        server.append_audit_log(
            "reconcile_loan_installment",
            args,
            "blocked_writes_disabled",
        );
        bail!(
            "Write operation refused: PATRIMONIO_MCP_ALLOW_WRITES is false (read-only mode is enforced by default). \
             Use dry_run=true to preview changes, or enable PATRIMONIO_MCP_ALLOW_WRITES=true with PATRIMONIO_WRITE_DATABASE_URL."
        );
    }

    let write_url = server.config.write_database_url.as_ref().ok_or_else(|| {
        anyhow!("PATRIMONIO_WRITE_DATABASE_URL is not configured; cannot execute write transaction")
    })?;

    let write_pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(5))
        .connect(write_url)
        .await
        .context("Failed to connect to PATRIMONIO_WRITE_DATABASE_URL")?;

    let res = sqlx::query(
        r#"
        UPDATE loan_payments
        SET status = $1,
            paid_amount = $2,
            paid_date = $3,
            actual_tx_id = $4
        WHERE user_id = $5 AND loan_id = $6 AND installment_number = $7
        "#,
    )
    .bind(new_status)
    .bind(paid_amount)
    .bind(paid_date)
    .bind(actual_tx_id)
    .bind(rt.user_id)
    .bind(loan_id)
    .bind(installment_number)
    .execute(&write_pool)
    .await?;

    server.append_audit_log("reconcile_loan_installment", args, "committed");

    Ok(json!({
        "dry_run": false,
        "committed": true,
        "rows_affected": res.rows_affected(),
        "before": before,
        "after": after
    }))
}

// =============================================================================
// JSON-RPC Dispatcher & Framing
// =============================================================================

async fn handle_request(server: &McpServer, req: JsonRpcRequest) -> Option<JsonRpcResponse> {
    // Notifications have no `id` and expect no response frame.
    let id = req.id?;

    let result: Result<Value, JsonRpcError> = match req.method.as_str() {
        "initialize" => {
            let client_version = req
                .params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(DEFAULT_PROTOCOL_VERSION);
            let negotiated = if matches!(client_version, "2024-11-05" | "2025-03-26" | "2025-06-18")
            {
                client_version
            } else {
                DEFAULT_PROTOCOL_VERSION
            };
            Ok(json!({
                "protocolVersion": negotiated,
                "capabilities": {
                    "tools": { "listChanged": false },
                    "resources": { "subscribe": false, "listChanged": false },
                    "prompts": { "listChanged": false }
                },
                "serverInfo": {
                    "name": SERVER_NAME,
                    "version": SERVER_VERSION
                },
                "instructions": "Patrimonio personal finance MCP server (US + Mexico). Read-only by default via least-privilege PostgreSQL role (patrimonio_mcp_ro). All cross-currency totals convert MXN to USD per row; all net worth histories use carry-forward across balance_snapshots."
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({
            "tools": tool_definitions(server.config.allow_writes)
        })),
        "tools/call" => {
            let tool_name = req
                .params
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let args = req
                .params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));

            let tool_outcome = dispatch_tool_by_name(server, tool_name, &args).await;

            match tool_outcome {
                Ok(payload) => {
                    let text = serde_json::to_string_pretty(&payload)
                        .unwrap_or_else(|_| payload.to_string());
                    Ok(json!({
                        "content": [
                            {
                                "type": "text",
                                "text": text
                            }
                        ],
                        "isError": false
                    }))
                }
                Err(e) => Ok(json!({
                    "content": [
                        {
                            "type": "text",
                            "text": format!("Error executing tool '{tool_name}': {e:#}")
                        }
                    ],
                    "isError": true
                })),
            }
        }
        "resources/list" => Ok(json!({
            "resources": resource_definitions()
        })),
        "resources/read" => {
            let uri = req
                .params
                .get("uri")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match uri {
                "patrimonio://schema/invariants" => Ok(json!({
                    "contents": [{
                        "uri": uri,
                        "mimeType": "text/markdown",
                        "text": concat!(
                            "# Patrimonio Domain & Security Invariants\n\n",
                            "1. **Carry-Forward Balance Snapshots**: Never `GROUP BY as_of_date` on `balance_snapshots` — carry each active account's most recent snapshot forward across dates.\n",
                            "2. **Per-Row USD/MXN Conversion**: Never sum raw `amount` or `current_balance` across currencies. Convert MXN rows using `LATEST_USD_MXN_RATE_SQL` (for current balances) or `USD_MXN_ROW_RATE_SQL` (for historical transactions).\n",
                            "3. **Plaid Reconnect vs Delete**: When an institution has `sync_status = 'reconnect_required'`, use Plaid Link Update Mode ('Reconnect') in Settings — never delete and re-add, which orphans historical transactions and snapshots.\n",
                            "4. **Least-Privilege Access**: The MCP server connects as `patrimonio_mcp_ro` with read-only transactions and column-level SELECT grants that block all encrypted tokens and password/TOTP hashes.\n"
                        )
                    }]
                })),
                "patrimonio://health/live" => match server.db().await {
                    Ok(rt) => match tool_audit_data_health(rt).await {
                        Ok(val) => Ok(json!({
                            "contents": [{
                                "uri": uri,
                                "mimeType": "application/json",
                                "text": serde_json::to_string_pretty(&val).unwrap_or_default()
                            }]
                        })),
                        Err(e) => Err(JsonRpcError {
                            code: -32603,
                            message: format!("Failed to read live health: {e:#}"),
                            data: None,
                        }),
                    },
                    Err(e) => Err(JsonRpcError {
                        code: -32603,
                        message: format!("Database connection error: {e:#}"),
                        data: None,
                    }),
                },
                _ => Err(JsonRpcError {
                    code: -32602,
                    message: format!("Unknown resource URI: {uri}"),
                    data: None,
                }),
            }
        }
        "prompts/list" => Ok(json!({
            "prompts": prompt_definitions()
        })),
        "prompts/get" => {
            let name = req
                .params
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let args = req
                .params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match name {
                "diagnose-net-worth-change" => {
                    let start = args
                        .get("start_date")
                        .and_then(Value::as_str)
                        .unwrap_or("30 days ago");
                    let end = args
                        .get("end_date")
                        .and_then(Value::as_str)
                        .unwrap_or("today");
                    Ok(json!({
                        "description": "Diagnose net worth changes and per-account attribution",
                        "messages": [{
                            "role": "user",
                            "content": {
                                "type": "text",
                                "text": format!(
                                    "Call `get_net_worth_history_and_movers` from {start} to {end} and `audit_data_health`. \
                                     Break down the net worth change by top account movers (market movement vs cash flow vs FX) \
                                     and flag any snapshot gaps or stale institutions."
                                )
                            }
                        }]
                    }))
                }
                "triage-accounts-and-sync" => Ok(json!({
                    "description": "Check archived accounts, Plaid reconnect items, and stale manual statement imports",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": "Call `list_accounts_and_sync_health` with `include_archived=true` and `only_issues=true`. Group findings into: (1) Plaid institutions needing Link update-mode reconnect, (2) manual institutions needing statement imports, and (3) archived accounts."
                        }
                    }]
                })),
                "audit-loan-repayments" => {
                    let borrower = args.get("borrower").and_then(Value::as_str).unwrap_or("");
                    Ok(json!({
                        "description": "Audit loan schedule and match transactions for a borrower",
                        "messages": [{
                            "role": "user",
                            "content": {
                                "type": "text",
                                "text": format!(
                                    "Call `get_loans_and_payments` with `borrower_query=\"{borrower}\"` and `search_transactions` with `query=\"{borrower}\"`. \
                                     Verify that every paid installment matches a real bank transaction in chronological installment order."
                                )
                            }
                        }]
                    }))
                }
                _ => Err(JsonRpcError {
                    code: -32602,
                    message: format!("Unknown prompt: {name}"),
                    data: None,
                }),
            }
        }
        method => Err(JsonRpcError {
            code: -32601,
            message: format!("Method not found: {method}"),
            data: None,
        }),
    };

    match result {
        Ok(val) => Some(JsonRpcResponse {
            jsonrpc: "2.0",
            id,
            result: Some(val),
            error: None,
        }),
        Err(err) => Some(JsonRpcResponse {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(err),
        }),
    }
}

async fn run_self_test(server: &McpServer) -> Result<()> {
    eprintln!("[self-test] Initializing DB connection and verifying security invariants...");
    let rt = server.db().await?;
    eprintln!(
        "[self-test] Connected as least-privilege role; resolved user_id={}",
        rt.user_id
    );

    // 1. Verify secret column access is blocked by PostgreSQL
    let secret_attempt = sqlx::query("SELECT plaid_access_token_enc FROM institutions LIMIT 1")
        .fetch_optional(&rt.pool)
        .await;
    if secret_attempt.is_ok() {
        bail!("SECURITY FAILURE: current database role was able to SELECT institutions.plaid_access_token_enc!");
    }
    eprintln!("[self-test] PASS: institutions.plaid_access_token_enc access denied by PostgreSQL");

    let pwd_attempt = sqlx::query("SELECT password_hash FROM users LIMIT 1")
        .fetch_optional(&rt.pool)
        .await;
    if pwd_attempt.is_ok() {
        bail!("SECURITY FAILURE: current database role was able to SELECT users.password_hash!");
    }
    eprintln!("[self-test] PASS: users.password_hash access denied by PostgreSQL");

    // 2. Verify read-only transaction enforcement
    let write_attempt = sqlx::query("DELETE FROM exchange_rates WHERE 1 = 0")
        .execute(&rt.pool)
        .await;
    if write_attempt.is_ok() {
        bail!("SECURITY FAILURE: read pool permitted a DELETE statement!");
    }
    eprintln!("[self-test] PASS: read-only transaction mode enforced by PostgreSQL");

    // 3. Verify core tools execute cleanly
    let nw = tool_get_net_worth_summary(rt).await?;
    eprintln!(
        "[self-test] PASS: get_net_worth_summary -> net_worth_usd={}",
        nw.get("net_worth_usd").unwrap_or(&json!(null))
    );

    let audit = tool_audit_data_health(rt).await?;
    let issue_count = audit
        .get("account_and_sync_issues")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    eprintln!("[self-test] PASS: audit_data_health -> {issue_count} account/sync issue(s) found");

    Ok(())
}

fn print_cli_help() {
    eprintln!(
        r#"{SERVER_NAME} v{SERVER_VERSION} — Patrimonio MCP Server & CLI

USAGE:
  {SERVER_NAME} [--config <path>] [SUBCOMMAND] [OPTIONS]

MODES / SUBCOMMANDS:
  (no subcommand) | serve            Run MCP JSON-RPC 2.0 server over stdio
  self-test | --self-test            Verify DB role security guards and tool health
  tools                              List all MCP tools and their schemas as JSON
  summary                            Get current net worth summary (USD/MXN, FX, institutions)
  movers [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--top N]
                                     Get carry-forward net worth history & top movers
  accounts [--issues] [--institution <name>] [--no-archived]
                                     List accounts and institution sync/import health
  transactions [--query <q>] [--institution <name>] [--category <cat>]
               [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--limit N]
                                     Search transactions with per-row USD conversion
  holdings [--symbol <ticker>] [--account-id <uuid>] [--lots]
                                     List active investment holdings (and optional lots)
  loans [--borrower <name>] [--status <status>] [--loan-id <uuid>]
                                     List loans, repayment schedules, and anomalies
  audit                              Run full Patrimonio data & sync health audit
  call <tool_name> ['<json_args>']   Invoke any MCP tool directly with JSON arguments
"#
    );
}

async fn dispatch_tool_by_name(server: &McpServer, tool_name: &str, args: &Value) -> Result<Value> {
    let rt = server.db().await?;
    match tool_name {
        "get_net_worth_summary" => tool_get_net_worth_summary(rt).await,
        "get_net_worth_history_and_movers" => tool_get_net_worth_history_and_movers(rt, args).await,
        "list_accounts_and_sync_health" => tool_list_accounts_and_sync_health(rt, args).await,
        "search_transactions" => tool_search_transactions(rt, args).await,
        "get_holdings_and_lots" => tool_get_holdings_and_lots(rt, args).await,
        "get_loans_and_payments" => tool_get_loans_and_payments(rt, args).await,
        "audit_data_health" => tool_audit_data_health(rt).await,
        "reconcile_loan_installment" => tool_reconcile_loan_installment(server, rt, args).await,
        other => bail!("Unknown tool '{other}'"),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut raw_args: Vec<String> = std::env::args().skip(1).collect();
    let mut config_path: Option<PathBuf> = None;

    // Extract global `--config <path>` anywhere in args
    let mut idx = 0;
    while idx < raw_args.len() {
        if raw_args.get(idx).is_some_and(|a| a == "--config") {
            raw_args.remove(idx);
            if idx >= raw_args.len() {
                bail!("--config requires a file path argument");
            }
            let p = raw_args.remove(idx);
            config_path = Some(PathBuf::from(p));
        } else {
            idx += 1;
        }
    }

    if raw_args
        .first()
        .is_some_and(|a| a == "--help" || a == "-h" || a == "help")
    {
        print_cli_help();
        return Ok(());
    }

    let config = McpConfig::load(config_path)?;
    let server = McpServer::new(config);

    if let Some(sub) = raw_args.first().map(String::as_str) {
        let rest = &raw_args[1..];
        match sub {
            "--self-test" | "self-test" => {
                return run_self_test(&server).await;
            }
            "tools" => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&tool_definitions(server.config.allow_writes))?
                );
                return Ok(());
            }
            "summary" => {
                let val =
                    dispatch_tool_by_name(&server, "get_net_worth_summary", &json!({})).await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "audit" => {
                let val = dispatch_tool_by_name(&server, "audit_data_health", &json!({})).await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "movers" => {
                let mut args = serde_json::Map::new();
                let mut i = 0;
                while i < rest.len() {
                    match rest.get(i).map(String::as_str) {
                        Some("--start") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--start requires YYYY-MM-DD"))?;
                            args.insert("start_date".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--end") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--end requires YYYY-MM-DD"))?;
                            args.insert("end_date".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--top") => {
                            let v: u64 = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--top requires an integer"))?
                                .parse()?;
                            args.insert("top_n".to_string(), json!(v));
                            i += 2;
                        }
                        Some(other) => bail!("Unknown movers option '{other}'"),
                        None => break,
                    }
                }
                let val = dispatch_tool_by_name(
                    &server,
                    "get_net_worth_history_and_movers",
                    &Value::Object(args),
                )
                .await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "accounts" => {
                let mut args = serde_json::Map::new();
                let mut i = 0;
                while i < rest.len() {
                    match rest.get(i).map(String::as_str) {
                        Some("--issues" | "--only-issues") => {
                            args.insert("only_issues".to_string(), json!(true));
                            i += 1;
                        }
                        Some("--no-archived") => {
                            args.insert("include_archived".to_string(), json!(false));
                            i += 1;
                        }
                        Some("--institution") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--institution requires a value"))?;
                            args.insert("institution_filter".to_string(), json!(v));
                            i += 2;
                        }
                        Some(other) => bail!("Unknown accounts option '{other}'"),
                        None => break,
                    }
                }
                let val = dispatch_tool_by_name(
                    &server,
                    "list_accounts_and_sync_health",
                    &Value::Object(args),
                )
                .await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "transactions" => {
                let mut args = serde_json::Map::new();
                let mut i = 0;
                while i < rest.len() {
                    match rest.get(i).map(String::as_str) {
                        Some("--query" | "-q") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--query requires text"))?;
                            args.insert("query".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--account-id") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--account-id requires UUID"))?;
                            args.insert("account_id".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--institution") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--institution requires text"))?;
                            args.insert("institution_name".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--category") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--category requires text"))?;
                            args.insert("category".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--start") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--start requires YYYY-MM-DD"))?;
                            args.insert("start_date".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--end") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--end requires YYYY-MM-DD"))?;
                            args.insert("end_date".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--limit") => {
                            let v: i64 = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--limit requires an integer"))?
                                .parse()?;
                            args.insert("limit".to_string(), json!(v));
                            i += 2;
                        }
                        Some(other) => bail!("Unknown transactions option '{other}'"),
                        None => break,
                    }
                }
                let val =
                    dispatch_tool_by_name(&server, "search_transactions", &Value::Object(args))
                        .await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "holdings" => {
                let mut args = serde_json::Map::new();
                let mut i = 0;
                while i < rest.len() {
                    match rest.get(i).map(String::as_str) {
                        Some("--symbol") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--symbol requires ticker"))?;
                            args.insert("symbol".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--account-id") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--account-id requires UUID"))?;
                            args.insert("account_id".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--lots") => {
                            args.insert("include_lots".to_string(), json!(true));
                            i += 1;
                        }
                        Some(other) => bail!("Unknown holdings option '{other}'"),
                        None => break,
                    }
                }
                let val =
                    dispatch_tool_by_name(&server, "get_holdings_and_lots", &Value::Object(args))
                        .await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "loans" => {
                let mut args = serde_json::Map::new();
                let mut i = 0;
                while i < rest.len() {
                    match rest.get(i).map(String::as_str) {
                        Some("--borrower") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--borrower requires text"))?;
                            args.insert("borrower_query".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--status") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--status requires status"))?;
                            args.insert("status".to_string(), json!(v));
                            i += 2;
                        }
                        Some("--loan-id") => {
                            let v = rest
                                .get(i + 1)
                                .ok_or_else(|| anyhow!("--loan-id requires UUID"))?;
                            args.insert("loan_id".to_string(), json!(v));
                            i += 2;
                        }
                        Some(other) => bail!("Unknown loans option '{other}'"),
                        None => break,
                    }
                }
                let val =
                    dispatch_tool_by_name(&server, "get_loans_and_payments", &Value::Object(args))
                        .await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "call" => {
                let tool_name = rest.first().ok_or_else(|| {
                    anyhow!("Usage: {SERVER_NAME} call <tool_name> ['<json_args>']")
                })?;
                let json_args: Value = match rest.get(1) {
                    Some(raw) => serde_json::from_str(raw)
                        .with_context(|| format!("Invalid JSON arguments: {raw}"))?,
                    None => json!({}),
                };
                let val = dispatch_tool_by_name(&server, tool_name, &json_args).await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "serve" => {
                // Fall through to stdio JSON-RPC loop
            }
            other => {
                bail!("Unknown subcommand or argument '{other}' (run `{SERVER_NAME} --help` for usage)");
            }
        }
    }

    let stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut reader = BufReader::new(stdin);
    let mut line = String::new();

    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            break; // EOF
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Support both newline-delimited JSON-RPC (MCP standard) and
        // Content-Length header framing.
        let payload_str = if let Some(rest) = trimmed.strip_prefix("Content-Length:") {
            let len: usize = rest
                .trim()
                .parse()
                .context("Invalid Content-Length header")?;
            // Consume remaining headers until blank line
            loop {
                line.clear();
                let h = reader.read_line(&mut line).await?;
                if h == 0 || line.trim().is_empty() {
                    break;
                }
            }
            let mut buf = vec![0u8; len];
            reader.read_exact(&mut buf).await?;
            String::from_utf8(buf).context("Invalid UTF-8 in JSON-RPC body")?
        } else {
            trimmed.to_string()
        };

        let parsed: Result<JsonRpcRequest, _> = serde_json::from_str(&payload_str);
        match parsed {
            Ok(req) => {
                if let Some(resp) = handle_request(&server, req).await {
                    let out = serde_json::to_string(&resp)?;
                    stdout.write_all(out.as_bytes()).await?;
                    stdout.write_all(b"\n").await?;
                    stdout.flush().await?;
                }
            }
            Err(e) => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0",
                    id: Value::Null,
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: format!("Parse error: {e}"),
                        data: None,
                    }),
                };
                let out = serde_json::to_string(&err_resp)?;
                stdout.write_all(out.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await?;
            }
        }
    }

    Ok(())
}
