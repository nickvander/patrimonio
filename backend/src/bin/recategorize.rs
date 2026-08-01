// Backfill categorizer — re-runs the rule-based categorizer over transactions
// that imported with a NULL `category` and stamps the category it now
// recognises. Existing (non-NULL) categories are NEVER touched.
//
// Motivation: statement/CSV imports (Nu "Cajitas", CetesDirecto principal
// movements, …) that the categorizer didn't recognise landed NULL. A NULL
// inflow is silently counted as INCOME in the cash-flow view, inflating income
// with money that is really an internal transfer or an investment principal
// move. After teaching `services::categorize` those patterns, this backfills
// the rows already in the database.
//
// Safe by construction: DRY-RUN by default (prints exactly what it would
// change, grouped by resulting category, with counts + totals + samples); pass
// `--apply` to write. `--user <username>` scopes it (optional when one user
// exists). Only rows WHERE category IS NULL are considered, and the UPDATE
// re-checks that guard, so it can't clobber a real category or double-apply.
//
// Usage:
//   DATABASE_URL=postgres://... cargo run --bin recategorize -- [user] [--apply]

use anyhow::{bail, Context, Result};
use rust_decimal::Decimal;
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use std::collections::BTreeMap;
use std::env;
use uuid::Uuid;

use patrimonio::services::categorize::{categorize, classify_cetes_movement};

#[tokio::main]
async fn main() -> Result<()> {
    let raw: Vec<String> = env::args().skip(1).collect();
    let apply = raw.iter().any(|a| a == "--apply");
    let user_arg: Option<String> = raw.iter().find(|a| !a.starts_with("--")).cloned();

    let db_url =
        env::var("DATABASE_URL").context("DATABASE_URL is required — point it at your Postgres")?;
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .connect(&db_url)
        .await
        .context("connecting to DATABASE_URL")?;

    let (user_id, username) = resolve_user(&pool, &user_arg).await?;
    println!("Recategorizing NULL-category transactions for '{username}' ({user_id})");
    println!(
        "Mode: {}\n",
        if apply {
            "APPLY (writing)"
        } else {
            "DRY-RUN (no writes) — pass --apply to write"
        }
    );

    // Pull every NULL-category row with the account name (so cetesdirecto rows
    // route to the CETES-specific classifier).
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.description, t.amount, a.name AS account_name
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.user_id = $1 AND t.category IS NULL
        "#,
    )
    .bind(user_id)
    .fetch_all(&pool)
    .await
    .context("fetching NULL-category transactions")?;

    // Stage the changes and tally by resulting category for the report.
    struct Change {
        id: Uuid,
        category: String,
        category_detailed: Option<String>,
    }
    struct Tally {
        n: u64,
        total_abs: Decimal,
        samples: Vec<String>,
    }
    let mut changes: Vec<Change> = Vec::new();
    let mut tally: BTreeMap<String, Tally> = BTreeMap::new();
    let total_null = rows.len();

    for r in &rows {
        let id: Uuid = r.get("id");
        let description: String = r.get("description");
        let amount: Decimal = r.get("amount");
        let account_name: String = r.get("account_name");

        // CetesDirecto rows use the CETES-aware classifier (which understands
        // BONDDIA/INGEFVO/AMORTIZACION principal moves + ISR + yield); every
        // other account uses the generic rule set.
        let resolved: Option<(String, Option<String>)> =
            if account_name.to_lowercase().contains("cetes") {
                classify_cetes_movement(&description, amount)
            } else {
                categorize(&description, amount).map(|c| (c, None))
            };

        if let Some((category, category_detailed)) = resolved {
            let entry = tally.entry(category.clone()).or_insert(Tally {
                n: 0,
                total_abs: Decimal::ZERO,
                samples: Vec::new(),
            });
            entry.n += 1;
            entry.total_abs += amount.abs();
            if entry.samples.len() < 3 {
                let d: String = description.chars().take(46).collect();
                entry.samples.push(d);
            }
            changes.push(Change {
                id,
                category,
                category_detailed,
            });
        }
    }

    // Report.
    println!(
        "{total_null} NULL-category rows scanned; {} would be categorized:\n",
        changes.len()
    );
    for (cat, t) in &tally {
        println!(
            "  {cat:<26} {:>5} rows   Σ|amount| {:>14.2}",
            t.n, t.total_abs
        );
        for s in &t.samples {
            println!("      e.g. {s}");
        }
    }
    let leftover = total_null - changes.len();
    println!(
        "\n  {:<26} {:>5} rows (still NULL — no confident rule)",
        "(unchanged)", leftover
    );

    if !apply {
        println!("\nDRY-RUN only. Re-run with --apply to write these categories.");
        return Ok(());
    }

    // Apply: one guarded UPDATE per row, inside a single transaction.
    let mut tx = pool.begin().await.context("begin apply tx")?;
    let mut written = 0u64;
    for c in &changes {
        let res = sqlx::query(
            r#"
            UPDATE transactions
            SET category = $1, category_detailed = $2
            WHERE id = $3 AND user_id = $4 AND category IS NULL
            "#,
        )
        .bind(&c.category)
        .bind(&c.category_detailed)
        .bind(c.id)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .context("applying categorization")?;
        written += res.rows_affected();
    }
    tx.commit().await.context("commit apply tx")?;
    println!("\nAPPLIED: {written} rows updated.");
    Ok(())
}

/// Resolve the target user: an explicit username, or the sole user when the DB
/// has exactly one (the common single-owner case).
async fn resolve_user(pool: &PgPool, user_arg: &Option<String>) -> Result<(Uuid, String)> {
    if let Some(name) = user_arg {
        let row = sqlx::query("SELECT id, username FROM users WHERE username = $1")
            .bind(name)
            .fetch_optional(pool)
            .await?
            .with_context(|| format!("no user named '{name}'"))?;
        return Ok((row.get("id"), row.get("username")));
    }
    let rows = sqlx::query("SELECT id, username FROM users ORDER BY created_at")
        .fetch_all(pool)
        .await?;
    match rows.len() {
        1 => Ok((rows[0].get("id"), rows[0].get("username"))),
        0 => bail!("no users in the database"),
        n => bail!("{n} users exist — pass a username, e.g. `recategorize <username>`"),
    }
}
