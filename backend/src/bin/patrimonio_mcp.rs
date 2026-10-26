//! Patrimonio Model Context Protocol (MCP) Server & CLI (`patrimonio_mcp`).
//!
//! Exposes a read-first, security-hardened MCP interface over `stdio` (as well
//! as ergonomic CLI subcommands) so AI agents and humans can inspect net worth,
//! carry-forward history, attribution movers, institution sync health,
//! transactions, holdings/lots, and loans without ever touching raw credentials
//! or risking cross-currency / snapshot bugs.
//!
//! ## Authentication & Transport Modes
//! `patrimonio-mcp` supports two first-class connection architectures:
//!
//! 1. **Personal Access Token + HTTP API Mode (Recommended for Users)**:
//!    - Authenticate once via `patrimonio-mcp login --url https://patrimonio.example.com`
//!      (or mint a `pat_...` token in Patrimonio via `POST /api/auth/tokens`).
//!    - Stores `PATRIMONIO_API_URL` and `PATRIMONIO_API_TOKEN` in
//!      `~/.config/patrimonio-mcp/config.env` (`chmod 0600`).
//!    - Communicates with the Patrimonio backend's Streamable HTTP MCP endpoint
//!      (`POST /api/mcp`) using `Authorization: Bearer pat_...`.
//!    - Requires **zero** SSH access and **zero** direct PostgreSQL credentials.
//!
//! 2. **Least-Privilege PostgreSQL / SSH Mode (For Homelab DB Operators)**:
//!    - Connects via `PATRIMONIO_MCP_DATABASE_URL` or an automatic loopback SSH
//!      tunnel (`PATRIMONIO_SSH_HOST`) using the restricted `patrimonio_mcp_ro`
//!      PostgreSQL role (`scripts/setup_mcp_role.sql`).
//!    - Enforces `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`,
//!      `SET statement_timeout = '10s'`, and `SET lock_timeout = '2s'` on every
//!      connection in `after_connect`.

use anyhow::{anyhow, bail, Context, Result};
use patrimonio::mcp::{
    dispatch_tool, execute_jsonrpc_with_context, handle_metadata_request, tool_definitions,
    JsonRpcRequest, JsonRpcResponse, McpExecutionContext, SERVER_NAME, SERVER_VERSION,
};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, Executor, PgPool, Row};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Write as IoWrite};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::OnceCell;
use uuid::Uuid;

#[derive(Debug, Clone)]
struct McpConfig {
    config_file_path: PathBuf,
    api_url: Option<String>,
    api_token: Option<String>,
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
    fn default_config_path() -> PathBuf {
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
            .unwrap_or_else(|| PathBuf::from("/tmp/patrimonio-mcp-config.env"))
    }

    fn load(config_path: Option<PathBuf>) -> Result<Self> {
        let resolved_path = config_path.unwrap_or_else(Self::default_config_path);

        let mut file_vars: HashMap<String, String> = HashMap::new();
        if resolved_path.exists() {
            verify_config_permissions(&resolved_path)?;
            let content = fs::read_to_string(&resolved_path).with_context(|| {
                format!("Failed to read config file {}", resolved_path.display())
            })?;
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

        let get_var = |key: &str| -> Option<String> {
            std::env::var(key)
                .ok()
                .filter(|v| !v.trim().is_empty())
                .or_else(|| file_vars.get(key).cloned().filter(|v| !v.trim().is_empty()))
        };

        let api_url = get_var("PATRIMONIO_API_URL").map(|u| u.trim_end_matches('/').to_string());
        let api_token = get_var("PATRIMONIO_API_TOKEN");
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
            config_file_path: resolved_path,
            api_url,
            api_token,
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

    fn is_http_api_mode(&self) -> bool {
        self.api_url.is_some() && self.api_token.is_some()
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
    write_pool: Option<PgPool>,
    user_id: Uuid,
    _ssh_tunnel: Option<Child>,
}

struct McpServer {
    config: McpConfig,
    http_client: reqwest::Client,
    db_cell: OnceCell<DbRuntime>,
}

impl McpServer {
    fn new(config: McpConfig) -> Result<Self> {
        let http_client = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .user_agent(format!("{SERVER_NAME}/{SERVER_VERSION}"))
            .build()
            .context("Failed to initialize HTTP client")?;
        Ok(Self {
            config,
            http_client,
            db_cell: OnceCell::new(),
        })
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
                "No Patrimonio connection configured. Run `{SERVER_NAME} login --url <https://your-patrimonio-url>` \
                 to authenticate with a Personal Access Token, or configure PATRIMONIO_MCP_DATABASE_URL / PATRIMONIO_SSH_HOST \
                 in {}.",
                self.config.config_file_path.display()
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

        let write_pool = if self.config.allow_writes {
            if let Some(ref wurl) = self.config.write_database_url {
                Some(
                    PgPoolOptions::new()
                        .max_connections(1)
                        .acquire_timeout(Duration::from_secs(6))
                        .connect(wurl)
                        .await
                        .context("Failed to connect to PATRIMONIO_WRITE_DATABASE_URL")?,
                )
            } else {
                None
            }
        } else {
            None
        };

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
            write_pool,
            user_id,
            _ssh_tunnel: ssh_child,
        })
    }

    async fn forward_jsonrpc_http(&self, req: &JsonRpcRequest) -> Result<Option<JsonRpcResponse>> {
        let base_url = self
            .config
            .api_url
            .as_deref()
            .ok_or_else(|| anyhow!("PATRIMONIO_API_URL is not configured"))?;
        let token = self
            .config
            .api_token
            .as_deref()
            .ok_or_else(|| anyhow!("PATRIMONIO_API_TOKEN is not configured"))?;
        let endpoint = format!("{base_url}/api/mcp");

        let resp = self
            .http_client
            .post(&endpoint)
            .header("Authorization", format!("Bearer {token}"))
            .json(req)
            .send()
            .await
            .with_context(|| format!("Failed to reach Patrimonio MCP endpoint at {endpoint}"))?;

        let status = resp.status();
        if status == reqwest::StatusCode::ACCEPTED {
            return Ok(None);
        }
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            let body = resp.text().await.unwrap_or_default();
            bail!(
                "Patrimonio API authentication failed ({status}): {body}. \
                 Run `{SERVER_NAME} login --url {base_url}` to refresh your Personal Access Token."
            );
        }
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            bail!("Patrimonio MCP HTTP error ({status}): {body}");
        }

        let rpc_resp: JsonRpcResponse = resp
            .json()
            .await
            .context("Failed to decode JSON-RPC response from Patrimonio /api/mcp")?;
        Ok(Some(rpc_resp))
    }

    async fn handle_jsonrpc(&self, req: JsonRpcRequest) -> Option<JsonRpcResponse> {
        let id = req.id.clone()?;

        // Answer static metadata requests locally with zero latency
        if let Some(meta_res) = handle_metadata_request(
            self.config.allow_writes || self.config.is_http_api_mode(),
            &req,
        ) {
            return Some(match meta_res {
                Ok(val) => JsonRpcResponse::ok(id, val),
                Err(err) => JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: None,
                    error: Some(err),
                },
            });
        }

        // Dynamic requests (`tools/call`, `resources/read` for `patrimonio://health/live`)
        if self.config.is_http_api_mode() {
            match self.forward_jsonrpc_http(&req).await {
                Ok(resp) => resp,
                Err(e) => Some(JsonRpcResponse::err(id, -32000, format!("{e:#}"))),
            }
        } else {
            let rt = match self.db().await {
                Ok(rt) => rt,
                Err(e) => {
                    return Some(JsonRpcResponse::err(
                        id,
                        -32000,
                        format!("Database initialization failed: {e:#}"),
                    ));
                }
            };
            let ctx = McpExecutionContext {
                pool: &rt.pool,
                user_id: rt.user_id,
                allow_writes: self.config.allow_writes,
                write_pool: rt.write_pool.as_ref(),
                audit_log_path: Some(&self.config.audit_log_path),
            };
            execute_jsonrpc_with_context(&ctx, req).await
        }
    }

    async fn call_tool_cli(&self, tool_name: &str, args: &Value) -> Result<Value> {
        if self.config.is_http_api_mode() {
            let req = JsonRpcRequest {
                jsonrpc: Some("2.0".to_string()),
                id: Some(json!(1)),
                method: "tools/call".to_string(),
                params: json!({
                    "name": tool_name,
                    "arguments": args,
                }),
            };
            let resp = self
                .forward_jsonrpc_http(&req)
                .await?
                .ok_or_else(|| anyhow!("Empty response from /api/mcp"))?;
            if let Some(err) = resp.error {
                bail!("MCP error ({}): {}", err.code, err.message);
            }
            let result = resp.result.unwrap_or_else(|| json!({}));
            if result.get("isError").and_then(Value::as_bool) == Some(true) {
                let msg = result
                    .get("content")
                    .and_then(Value::as_array)
                    .and_then(|a| a.first())
                    .and_then(|c| c.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or("Tool execution failed");
                bail!("{msg}");
            }
            if let Some(structured) = result.get("structuredContent") {
                return Ok(structured.clone());
            }
            Ok(result)
        } else {
            let rt = self.db().await?;
            let ctx = McpExecutionContext {
                pool: &rt.pool,
                user_id: rt.user_id,
                allow_writes: self.config.allow_writes,
                write_pool: rt.write_pool.as_ref(),
                audit_log_path: Some(&self.config.audit_log_path),
            };
            dispatch_tool(&ctx, tool_name, args).await
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

// =============================================================================
// Interactive Login & Personal Access Token Minting
// =============================================================================

fn prompt_line(prompt: &str) -> Result<String> {
    eprint!("{prompt}");
    io::stderr().flush()?;
    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    Ok(buf.trim().to_string())
}

fn extract_session_cookie(headers: &reqwest::header::HeaderMap) -> Option<String> {
    for val in headers.get_all(reqwest::header::SET_COOKIE) {
        if let Ok(raw) = val.to_str() {
            if let Some(first_pair) = raw.split(';').next() {
                if let Some(token) = first_pair.trim().strip_prefix("patrimonio_session=") {
                    if !token.is_empty() {
                        return Some(token.to_string());
                    }
                }
            }
        }
    }
    None
}

async fn run_login(config_path: &Path, args: &[String]) -> Result<()> {
    let mut base_url = std::env::var("PATRIMONIO_API_URL").ok();
    let mut username = std::env::var("PATRIMONIO_USERNAME").ok();
    let mut password = std::env::var("PATRIMONIO_PASSWORD").ok();
    let mut totp_code: Option<String> = None;
    let mut token_name = format!(
        "patrimonio-mcp ({})",
        std::env::var("HOSTNAME")
            .or_else(|_| std::env::var("USER"))
            .unwrap_or_else(|_| "cli".to_string())
    );
    let mut scope = "read_only".to_string();
    let mut expires_in_days: Option<i64> = Some(90);

    let mut i = 0;
    while i < args.len() {
        match args.get(i).map(String::as_str) {
            Some("--url" | "-u") => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--url requires a Patrimonio base URL"))?;
                base_url = Some(v.clone());
                i += 2;
            }
            Some("--username") => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--username requires a value"))?;
                username = Some(v.clone());
                i += 2;
            }
            Some("--password") => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--password requires a value"))?;
                password = Some(v.clone());
                i += 2;
            }
            Some("--totp") => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--totp requires a 6-digit code or recovery code"))?;
                totp_code = Some(v.clone());
                i += 2;
            }
            Some("--name") => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--name requires a token label"))?;
                token_name = v.clone();
                i += 2;
            }
            Some("--scope") => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--scope requires read_only or read_write"))?;
                if v != "read_only" && v != "read_write" {
                    bail!("--scope must be 'read_only' or 'read_write'");
                }
                scope = v.clone();
                i += 2;
            }
            Some("--expires-days") => {
                let v: i64 = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("--expires-days requires an integer (0 for no expiry)"))?
                    .parse()?;
                expires_in_days = if v <= 0 { None } else { Some(v) };
                i += 2;
            }
            Some(other) => bail!("Unknown login option '{other}'"),
            None => break,
        }
    }

    let base_url = match base_url {
        Some(u) if !u.trim().is_empty() => u.trim().trim_end_matches('/').to_string(),
        _ => {
            let entered = prompt_line("Patrimonio URL (e.g. https://patrimonio.example.com): ")?;
            if entered.is_empty() {
                bail!("Patrimonio URL is required");
            }
            entered.trim_end_matches('/').to_string()
        }
    };

    let username = match username {
        Some(u) if !u.trim().is_empty() => u,
        _ => {
            let entered = prompt_line("Username: ")?;
            if entered.is_empty() {
                bail!("Username is required");
            }
            entered
        }
    };

    let password = match password {
        Some(p) if !p.is_empty() => p,
        _ => {
            let entered = prompt_line("Password: ")?;
            if entered.is_empty() {
                bail!("Password is required");
            }
            entered
        }
    };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent(format!("{SERVER_NAME}/{SERVER_VERSION}"))
        .build()?;

    eprintln!("[login] Authenticating with {base_url} as '{username}'...");
    let login_resp = client
        .post(format!("{base_url}/api/auth/login"))
        .header("X-Requested-With", SERVER_NAME)
        .json(&json!({
            "username": username,
            "password": password,
        }))
        .send()
        .await
        .with_context(|| format!("Failed to connect to {base_url}/api/auth/login"))?;

    if !login_resp.status().is_success() {
        let status = login_resp.status();
        let body = login_resp.text().await.unwrap_or_default();
        bail!("Login failed ({status}): {body}");
    }

    let mut session_cookie = extract_session_cookie(login_resp.headers())
        .ok_or_else(|| anyhow!("Server did not return a patrimonio_session cookie"))?;
    let login_json: Value = login_resp.json().await.unwrap_or_else(|_| json!({}));

    if login_json.get("requires_totp").and_then(Value::as_bool) == Some(true) {
        let code = match totp_code {
            Some(c) if !c.trim().is_empty() => c,
            _ => prompt_line("2FA TOTP Code (or recovery code): ")?,
        };
        let totp_resp = client
            .post(format!("{base_url}/api/auth/totp/verify"))
            .header("X-Requested-With", SERVER_NAME)
            .header("Cookie", format!("patrimonio_session={session_cookie}"))
            .json(&json!({ "code": code }))
            .send()
            .await
            .context("Failed to verify TOTP code")?;

        if !totp_resp.status().is_success() {
            let status = totp_resp.status();
            let body = totp_resp.text().await.unwrap_or_default();
            bail!("2FA verification failed ({status}): {body}");
        }
        if let Some(rotated) = extract_session_cookie(totp_resp.headers()) {
            session_cookie = rotated;
        }
    }

    // Mint Personal Access Token
    eprintln!("[login] Minting '{scope}' Personal Access Token ({token_name})...");
    let token_resp = client
        .post(format!("{base_url}/api/auth/tokens"))
        .header("X-Requested-With", SERVER_NAME)
        .header("Cookie", format!("patrimonio_session={session_cookie}"))
        .json(&json!({
            "name": token_name,
            "scope": scope,
            "expires_in_days": expires_in_days,
        }))
        .send()
        .await
        .context("Failed to call POST /api/auth/tokens")?;

    if !token_resp.status().is_success() {
        let status = token_resp.status();
        let body = token_resp.text().await.unwrap_or_default();
        bail!("Failed to create Personal Access Token ({status}): {body}");
    }

    let token_json: Value = token_resp.json().await?;
    let raw_pat = token_json
        .get("token")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Server response missing 'token' field"))?;

    // Immediately revoke the temporary interactive session cookie so only the
    // scoped Personal Access Token remains active.
    let _ = client
        .post(format!("{base_url}/api/auth/logout"))
        .header("X-Requested-With", SERVER_NAME)
        .header("Cookie", format!("patrimonio_session={session_cookie}"))
        .send()
        .await;

    save_token_to_config_file(config_path, &base_url, raw_pat)?;

    eprintln!(
        "[login] Saved Personal Access Token ({}) to {}",
        token_json
            .get("token_prefix")
            .and_then(Value::as_str)
            .unwrap_or("pat_..."),
        config_path.display()
    );
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "status": "authenticated",
            "mode": "http_api_token",
            "api_url": base_url,
            "config_file": config_path.display().to_string(),
            "token_id": token_json.get("id"),
            "token_name": token_json.get("name"),
            "token_prefix": token_json.get("token_prefix"),
            "scope": token_json.get("scope"),
            "expires_at": token_json.get("expires_at"),
        }))?
    );
    Ok(())
}

fn save_token_to_config_file(config_path: &Path, api_url: &str, api_token: &str) -> Result<()> {
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut preserved_lines: Vec<String> = Vec::new();
    if config_path.exists() {
        if let Ok(existing) = fs::read_to_string(config_path) {
            for line in existing.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("PATRIMONIO_API_URL=")
                    || trimmed.starts_with("PATRIMONIO_API_TOKEN=")
                {
                    continue;
                }
                preserved_lines.push(line.to_string());
            }
        }
    }

    preserved_lines.push(format!("PATRIMONIO_API_URL={api_url}"));
    preserved_lines.push(format!("PATRIMONIO_API_TOKEN={api_token}"));
    let final_content = format!("{}\n", preserved_lines.join("\n").trim());

    fs::write(config_path, final_content)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(config_path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

async fn run_self_test(server: &McpServer) -> Result<()> {
    if server.config.is_http_api_mode() {
        let base_url = server.config.api_url.as_deref().unwrap_or_default();
        eprintln!(
            "[self-test] Verifying HTTP API mode + Personal Access Token against {base_url}..."
        );
        let nw = server
            .call_tool_cli("get_net_worth_summary", &json!({}))
            .await?;
        eprintln!(
            "[self-test] PASS: get_net_worth_summary -> net_worth_usd={}",
            nw.get("net_worth_usd").unwrap_or(&json!(null))
        );
        let audit = server
            .call_tool_cli("audit_data_health", &json!({}))
            .await?;
        let issue_count = audit
            .get("account_and_sync_issues")
            .and_then(Value::as_array)
            .map_or(0, Vec::len);
        eprintln!(
            "[self-test] PASS: audit_data_health -> {issue_count} account/sync issue(s) found"
        );
        return Ok(());
    }

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
    let nw = server
        .call_tool_cli("get_net_worth_summary", &json!({}))
        .await?;
    eprintln!(
        "[self-test] PASS: get_net_worth_summary -> net_worth_usd={}",
        nw.get("net_worth_usd").unwrap_or(&json!(null))
    );

    let audit = server
        .call_tool_cli("audit_data_health", &json!({}))
        .await?;
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

AUTHENTICATION & CONNECTION MODES:
  login --url <https://...> [--username <u>] [--scope read_only|read_write] [--expires-days <N>]
                                     Sign in to Patrimonio, mint a scoped Personal Access Token
                                     (pat_...), and save it to ~/.config/patrimonio-mcp/config.env

MCP & CLI SUBCOMMANDS:
  (no subcommand) | serve            Run MCP JSON-RPC 2.0 server over stdio
  self-test | --self-test            Verify authentication/DB security guards and tool health
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

    if raw_args.first().is_some_and(|a| a == "login") {
        let resolved = config_path.unwrap_or_else(McpConfig::default_config_path);
        return run_login(&resolved, &raw_args[1..]).await;
    }

    let config = McpConfig::load(config_path)?;
    let server = McpServer::new(config)?;

    if let Some(sub) = raw_args.first().map(String::as_str) {
        let rest = &raw_args[1..];
        match sub {
            "--self-test" | "self-test" => {
                return run_self_test(&server).await;
            }
            "tools" => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&tool_definitions(
                        server.config.allow_writes || server.config.is_http_api_mode()
                    ))?
                );
                return Ok(());
            }
            "summary" => {
                let val = server
                    .call_tool_cli("get_net_worth_summary", &json!({}))
                    .await?;
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            "audit" => {
                let val = server
                    .call_tool_cli("audit_data_health", &json!({}))
                    .await?;
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
                let val = server
                    .call_tool_cli("get_net_worth_history_and_movers", &Value::Object(args))
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
                let val = server
                    .call_tool_cli("list_accounts_and_sync_health", &Value::Object(args))
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
                let val = server
                    .call_tool_cli("search_transactions", &Value::Object(args))
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
                let val = server
                    .call_tool_cli("get_holdings_and_lots", &Value::Object(args))
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
                let val = server
                    .call_tool_cli("get_loans_and_payments", &Value::Object(args))
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
                let val = server.call_tool_cli(tool_name, &json_args).await?;
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
                if let Some(resp) = server.handle_jsonrpc(req).await {
                    let out = serde_json::to_string(&resp)?;
                    stdout.write_all(out.as_bytes()).await?;
                    stdout.write_all(b"\n").await?;
                    stdout.flush().await?;
                }
            }
            Err(e) => {
                let err_resp =
                    JsonRpcResponse::err(Value::Null, -32700, format!("Parse error: {e}"));
                let out = serde_json::to_string(&err_resp)?;
                stdout.write_all(out.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await?;
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_server(allow_writes: bool) -> McpServer {
        McpServer::new(McpConfig {
            config_file_path: PathBuf::from("/tmp/patrimonio-mcp-test.env"),
            api_url: None,
            api_token: None,
            database_url: None,
            ssh_host: None,
            ssh_remote_port: 5433,
            db_user: "patrimonio_mcp_ro".to_string(),
            db_password: String::new(),
            db_name: "patrimonio".to_string(),
            user_id: None,
            allow_writes,
            write_database_url: None,
            audit_log_path: PathBuf::from("/tmp/patrimonio-mcp-test-audit.jsonl"),
        })
        .expect("build test server")
    }

    #[tokio::test]
    async fn initialize_returns_protocol_and_capabilities() {
        let server = test_server(false);
        let req = JsonRpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!(1)),
            method: "initialize".to_string(),
            params: json!({ "protocolVersion": "2024-11-05" }),
        };
        let resp = server.handle_jsonrpc(req).await.expect("response expected");
        assert!(resp.error.is_none());
        let res = resp.result.expect("result present");
        assert_eq!(res["protocolVersion"], "2024-11-05");
        assert_eq!(res["serverInfo"]["name"], "patrimonio-mcp");
    }

    #[tokio::test]
    async fn tools_list_reflects_write_permission_state() {
        let ro_server = test_server(false);
        let req = JsonRpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!(2)),
            method: "tools/list".to_string(),
            params: json!({}),
        };
        let resp = ro_server.handle_jsonrpc(req).await.unwrap();
        let tools = resp.result.unwrap()["tools"].as_array().unwrap().clone();
        assert_eq!(tools.len(), 8);
        let ro_reconcile = tools
            .iter()
            .find(|t| t["name"] == "reconcile_loan_installment")
            .unwrap();
        assert!(ro_reconcile["description"]
            .as_str()
            .unwrap()
            .contains("currently: false"));

        let rw_server = test_server(true);
        let req2 = JsonRpcRequest {
            jsonrpc: Some("2.0".to_string()),
            id: Some(json!(3)),
            method: "tools/list".to_string(),
            params: json!({}),
        };
        let resp2 = rw_server.handle_jsonrpc(req2).await.unwrap();
        let tools2 = resp2.result.unwrap()["tools"].as_array().unwrap().clone();
        assert_eq!(tools2.len(), 8);
        let rw_reconcile = tools2
            .iter()
            .find(|t| t["name"] == "reconcile_loan_installment")
            .unwrap();
        assert!(rw_reconcile["description"]
            .as_str()
            .unwrap()
            .contains("currently: true"));
    }

    #[cfg(unix)]
    #[test]
    fn config_permission_check_rejects_world_readable_files() {
        use std::os::unix::fs::PermissionsExt;
        let path =
            std::env::temp_dir().join(format!("patrimonio_mcp_perm_test_{}.env", Uuid::new_v4()));
        fs::write(&path, "PATRIMONIO_DB_USER=patrimonio_mcp_ro\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        let err = verify_config_permissions(&path).unwrap_err();
        assert!(err.to_string().contains("insecure permissions"));

        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(verify_config_permissions(&path).is_ok());
        let _ = fs::remove_file(&path);
    }
}
