// Break-glass admin CLI — local recovery for a self-hosted owner who is
// locked out of their own instance.
//
// There is deliberately NO authenticated API route for any of this: the
// only "credential" is shell access to the box running Postgres, which a
// self-hoster already has. Run it directly against the database (the API
// can stay up; every operation is a single idempotent statement).
//
// Every mutation asks for confirmation (type `yes`), or pass `--yes` to
// skip the prompt for scripted use, and is written to `auth_audit` so the
// break-glass event is visible in the login history afterwards.
//
// Usage:
//   DATABASE_URL=postgres://... cargo run --bin admin_reset -- <command> [user]
//
//   list                              Show users (TOTP / active / unused recovery codes)
//   reset-password [user] [--password <pw>]
//                                     Reset the password (generates a strong one if omitted),
//                                     and revoke all sessions.
//   disable-totp [user]               Turn off TOTP / 2FA (clears the secret).
//   recovery-codes [user]             Generate a fresh batch of recovery codes and print them.
//   reactivate [user]                 Re-enable a deactivated (is_active=false) account.
//   revoke-sessions [user]            Sign the user out everywhere.
//
//   [user] is optional when exactly one user exists (the common single-owner case).
//   Add --yes / -y to any mutating command to skip the confirmation prompt.
//
// Example — forgot the password on the homelab box:
//   DATABASE_URL=postgres://patrimonio:patrimonio@127.0.0.1:5433/patrimonio \
//     cargo run --bin admin_reset -- reset-password

use anyhow::{bail, Context, Result};
use rand::{rngs::OsRng, RngCore};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use std::env;
use std::io::{self, IsTerminal, Write};
use uuid::Uuid;

use patrimonio::services::{password, recovery, sessions};

#[tokio::main]
async fn main() -> Result<()> {
    let raw: Vec<String> = env::args().skip(1).collect();

    // Parse: --yes/-y flag, --password <val> / --password=<val>, positionals.
    let yes = raw.iter().any(|a| a == "--yes" || a == "-y");
    let mut pw_opt: Option<String> = None;
    let mut positionals: Vec<String> = Vec::new();
    let mut it = raw
        .iter()
        .filter(|a| *a != "--yes" && *a != "-y")
        .peekable();
    while let Some(a) = it.next() {
        if a == "--password" {
            pw_opt = it.next().cloned();
        } else if let Some(v) = a.strip_prefix("--password=") {
            pw_opt = Some(v.to_string());
        } else {
            positionals.push(a.clone());
        }
    }

    let cmd = positionals.first().map(|s| s.as_str()).unwrap_or("help");
    if matches!(cmd, "help" | "--help" | "-h") {
        print_usage();
        return Ok(());
    }
    let user_arg = positionals.get(1).cloned();

    let db_url = env::var("DATABASE_URL")
        .context("DATABASE_URL is required — point it at your Postgres (see docker-compose.yml)")?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await
        .context("connecting to DATABASE_URL")?;

    match cmd {
        "list" => list_users(&pool).await?,
        "reset-password" => {
            let (id, uname) = resolve_user(&pool, &user_arg).await?;
            reset_password(&pool, id, &uname, pw_opt, yes).await?;
        }
        "disable-totp" => {
            let (id, uname) = resolve_user(&pool, &user_arg).await?;
            disable_totp(&pool, id, &uname, yes).await?;
        }
        "recovery-codes" => {
            let (id, uname) = resolve_user(&pool, &user_arg).await?;
            regen_recovery_codes(&pool, id, &uname, yes).await?;
        }
        "reactivate" => {
            let (id, uname) = resolve_user(&pool, &user_arg).await?;
            reactivate(&pool, id, &uname, yes).await?;
        }
        "revoke-sessions" => {
            let (id, uname) = resolve_user(&pool, &user_arg).await?;
            revoke_sessions(&pool, id, &uname, yes).await?;
        }
        other => {
            eprintln!("unknown command: {other}\n");
            print_usage();
            std::process::exit(2);
        }
    }
    Ok(())
}

fn print_usage() {
    println!(
        "Break-glass admin CLI (run locally against the DB)\n\n\
         Usage: DATABASE_URL=... cargo run --bin admin_reset -- <command> [user] [--yes]\n\n\
         Commands:\n\
         \x20 list                              Show users (TOTP / active / unused recovery codes)\n\
         \x20 reset-password [user] [--password <pw>]   Reset password (auto-generates if omitted) + sign out everywhere\n\
         \x20 disable-totp [user]               Turn off TOTP / 2FA\n\
         \x20 recovery-codes [user]             Generate + print a fresh batch of recovery codes\n\
         \x20 reactivate [user]                 Re-enable a deactivated account\n\
         \x20 revoke-sessions [user]            Sign the user out on every device\n\n\
         [user] is optional when there is exactly one user. Add --yes to skip confirmation."
    );
}

/// Resolve a user by username (case-insensitive); when no name is given and
/// exactly one user exists, use that one (the single-owner default).
async fn resolve_user(pool: &PgPool, arg: &Option<String>) -> Result<(Uuid, String)> {
    if let Some(name) = arg {
        let row = sqlx::query("SELECT id, username FROM users WHERE LOWER(username) = LOWER($1)")
            .bind(name)
            .fetch_optional(pool)
            .await?;
        match row {
            Some(r) => Ok((r.get("id"), r.get("username"))),
            None => bail!("no user named '{name}' (try `list`)"),
        }
    } else {
        let rows = sqlx::query("SELECT id, username FROM users ORDER BY LOWER(username)")
            .fetch_all(pool)
            .await?;
        match rows.len() {
            0 => bail!("no users exist yet — run the app's first-time bootstrap instead"),
            1 => Ok((rows[0].get("id"), rows[0].get("username"))),
            _ => bail!("multiple users exist — pass a username (see `list`)"),
        }
    }
}

fn confirm(yes: bool, action: &str) -> Result<bool> {
    if yes {
        return Ok(true);
    }
    if !io::stdin().is_terminal() {
        bail!("not a TTY and --yes was not given — refusing to {action} unprompted");
    }
    print!("About to {action}. Type 'yes' to proceed: ");
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin().read_line(&mut line)?;
    Ok(line.trim() == "yes")
}

/// 24 hex chars (~96 bits). Passes the password policy (≥12 chars, not a
/// common-breach entry) without needing the operator to invent one.
fn generate_password() -> String {
    let mut b = [0u8; 12];
    OsRng.fill_bytes(&mut b);
    hex::encode(b)
}

async fn audit(pool: &PgPool, event: &str, user_id: Uuid, uname: &str) {
    let _ = sqlx::query(
        "INSERT INTO auth_audit (event, username_attempt, user_id, ip_address, user_agent, success, detail) \
         VALUES ($1, $2, $3, NULL, $4, true, $5)",
    )
    .bind(event)
    .bind(uname)
    .bind(user_id)
    .bind("admin_reset CLI")
    .bind("break-glass admin CLI")
    .execute(pool)
    .await;
}

async fn list_users(pool: &PgPool) -> Result<()> {
    let rows = sqlx::query(
        "SELECT id, username, totp_enabled, is_active FROM users ORDER BY LOWER(username)",
    )
    .fetch_all(pool)
    .await?;
    if rows.is_empty() {
        println!("(no users — run the app's bootstrap flow)");
        return Ok(());
    }
    println!(
        "{:<38}  {:<20}  {:<6}  {:<7}  recovery_codes_left",
        "id", "username", "totp", "active"
    );
    for r in &rows {
        let id: Uuid = r.get("id");
        let uname: String = r.get("username");
        let totp: bool = r.get("totp_enabled");
        let active: bool = r.get("is_active");
        let left = recovery::unused_count(pool, id).await.unwrap_or(-1);
        println!(
            "{:<38}  {:<20}  {:<6}  {:<7}  {}",
            id.to_string(),
            uname,
            if totp { "on" } else { "off" },
            if active { "yes" } else { "NO" },
            left
        );
    }
    Ok(())
}

async fn reset_password(
    pool: &PgPool,
    id: Uuid,
    uname: &str,
    pw_opt: Option<String>,
    yes: bool,
) -> Result<()> {
    let generated = pw_opt.is_none();
    let pw = pw_opt.unwrap_or_else(generate_password);
    password::validate_password_policy(&pw)
        .context("the supplied password was rejected by the policy")?;
    if !confirm(
        yes,
        &format!("reset the password for '{uname}' (revokes all sessions)"),
    )? {
        println!("aborted.");
        return Ok(());
    }
    let hash = password::hash_password(&pw)?;
    sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
        .bind(&hash)
        .bind(id)
        .execute(pool)
        .await?;
    sessions::revoke_all_for_user(pool, id).await.ok();
    audit(pool, "admin_reset_password", id, uname).await;
    println!("✓ password reset for '{uname}'; all sessions revoked.");
    if generated {
        println!();
        println!("  New password: {pw}");
        println!("  (store it now — it is not saved anywhere and won't be shown again)");
    }
    Ok(())
}

async fn disable_totp(pool: &PgPool, id: Uuid, uname: &str, yes: bool) -> Result<()> {
    if !confirm(yes, &format!("disable TOTP / 2FA for '{uname}'"))? {
        println!("aborted.");
        return Ok(());
    }
    sqlx::query("UPDATE users SET totp_secret_enc = NULL, totp_enabled = false WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    audit(pool, "admin_disable_totp", id, uname).await;
    println!("✓ TOTP disabled for '{uname}'. Re-enroll from Settings after you log in.");
    Ok(())
}

async fn regen_recovery_codes(pool: &PgPool, id: Uuid, uname: &str, yes: bool) -> Result<()> {
    if !confirm(
        yes,
        &format!("regenerate recovery codes for '{uname}' (invalidates the old batch)"),
    )? {
        println!("aborted.");
        return Ok(());
    }
    let codes = recovery::regenerate(pool, id).await?;
    audit(pool, "admin_regen_recovery_codes", id, uname).await;
    println!("✓ new recovery codes for '{uname}' (store these offline — shown once):");
    println!();
    for c in &codes {
        println!("    {c}");
    }
    Ok(())
}

async fn reactivate(pool: &PgPool, id: Uuid, uname: &str, yes: bool) -> Result<()> {
    if !confirm(yes, &format!("re-activate '{uname}'"))? {
        println!("aborted.");
        return Ok(());
    }
    sqlx::query("UPDATE users SET is_active = true WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    audit(pool, "admin_reactivate", id, uname).await;
    println!("✓ '{uname}' re-activated.");
    Ok(())
}

async fn revoke_sessions(pool: &PgPool, id: Uuid, uname: &str, yes: bool) -> Result<()> {
    if !confirm(yes, &format!("sign '{uname}' out on every device"))? {
        println!("aborted.");
        return Ok(());
    }
    sessions::revoke_all_for_user(pool, id).await?;
    audit(pool, "admin_revoke_sessions", id, uname).await;
    println!("✓ all sessions revoked for '{uname}'.");
    Ok(())
}
