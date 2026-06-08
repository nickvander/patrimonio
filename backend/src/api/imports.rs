use axum::{
    extract::{DefaultBodyLimit, Extension, Multipart, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use tokio::sync::RwLock;
use tracing::{error, info};
use uuid::Uuid;

use crate::api::session::AuthContext;
use crate::services::parser;
use crate::AppState;

use crate::models::import::ParsedTransaction;

/// A parsed transaction plus the file it came from, for the import
/// preview. `#[serde(flatten)]` keeps the wire shape identical to
/// `ParsedTransaction` with one extra `source_file` key — so the frontend
/// reads `tx['source_file']` to group/exclude by file, and the confirm
/// endpoint (which deserializes a plain `ParsedTransaction`) just ignores
/// the extra key.
#[derive(Serialize, Deserialize)]
pub struct PreviewTx {
    #[serde(flatten)]
    pub tx: ParsedTransaction,
    pub source_file: String,
}

#[derive(Serialize, Deserialize)]
pub struct ImportResponse {
    pub message: String,
    pub status: String,
    pub transactions_count: usize,
    pub transactions: Vec<PreviewTx>,
    /// Account metadata lifted from the newest statement (CLABE, holder,
    /// suggested name + balance) so the import UI can pre-fill a new account.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub account_info: Option<parser::AccountInfo>,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/upload",
            // 100MB cap. A year of monthly Banamex / Nu Mexico PDFs
            // (typically 3-5MB each) lands around 40-60MB; the old
            // 20MB limit truncated the multipart stream mid-upload
            // with the misleading `failed to read stream` error.
            // 100MB gives ~2× headroom over a normal year's worth.
            post(upload_handler).layer(DefaultBodyLimit::max(100 * 1024 * 1024)),
        )
        // Per-file progress side-channel. The client generates a
        // UUID, sends it as `X-Upload-Job-Id` on POST /upload, AND
        // concurrently polls this endpoint every ~250 ms. The
        // upload itself stays synchronous (the response is the
        // legacy single-shot JSON) — progress is rendered from the
        // separate poll. This avoids the bidirectional-stream RST
        // that broke the first streaming attempt.
        .route("/progress/{job_id}", get(progress_handler))
        .route("/confirm", post(confirm_handler))
        // Preview-time duplicate check: given the chosen account + parsed
        // rows, return which are already imported so the UI can flag /
        // auto-deselect them BEFORE confirming.
        .route("/check-duplicates", post(check_duplicates_handler))
        // Import cleanup: list past import batches, undo one, or bulk-
        // delete transactions in an account + date range.
        // Full-history statement continuity: per account, chain the stored
        // running balances across every imported statement and report likely
        // missing months. Complements the in-batch check done at confirm.
        .route("/continuity", get(continuity_handler))
        .route("/batches", get(list_batches_handler))
        .route("/batches/{id}", axum::routing::delete(undo_batch_handler))
        .route("/transactions/bulk-delete", post(bulk_delete_handler))
}

/// The dedup key for an imported transaction. MUST stay identical to the
/// signature `confirm_handler` inserts, so a row the preview marks
/// "already imported" is exactly the row confirm would skip.
fn tx_signature(date: &chrono::NaiveDate, amount: &rust_decimal::Decimal, description: &str) -> String {
    format!(
        "manual:{}:{}:{}",
        date,
        amount,
        description.to_lowercase().chars().take(50).collect::<String>()
    )
}

/// Occurrence-aware signatures for an ordered batch of rows.
///
/// The bare `tx_signature` collapses two genuinely-distinct rows that share a
/// date + amount + (first 50 chars of) description into one external_id — so
/// the second was silently dropped on import (ON CONFLICT DO NOTHING). This
/// disambiguates exact duplicates WITHIN the batch by an occurrence suffix.
///
/// Backward-compatibility is load-bearing: the FIRST occurrence keeps the
/// legacy bare signature, so the user's entire already-imported history
/// (written under the old scheme) still matches and re-imports stay
/// idempotent. Only the 2nd+ identical row in a batch gets a `#N` suffix,
/// which recovers the previously-lost duplicate without duplicating anything
/// that already exists.
fn batch_signatures(
    rows: impl IntoIterator<Item = (chrono::NaiveDate, rust_decimal::Decimal, String)>,
) -> Vec<String> {
    let mut seen: HashMap<String, usize> = HashMap::new();
    rows.into_iter()
        .map(|(date, amount, desc)| {
            let base = tx_signature(&date, &amount, &desc);
            let n = seen.entry(base.clone()).or_insert(0);
            let sig = if *n == 0 {
                base.clone()
            } else {
                format!("{base}#{n}")
            };
            *n += 1;
            sig
        })
        .collect()
}

#[derive(Deserialize)]
struct CheckDuplicatesRequest {
    account_id: uuid::Uuid,
    transactions: Vec<ParsedTransaction>,
}

/// Returns the indices (into the submitted `transactions` array) that
/// already exist in the chosen account — by the same signature confirm
/// dedups on. Scoped to the caller's own account.
async fn check_duplicates_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(req): Json<CheckDuplicatesRequest>,
) -> Response {
    let sigs: Vec<String> = batch_signatures(
        req.transactions
            .iter()
            .map(|t| (t.date, t.amount, t.description.clone())),
    );

    let existing: Vec<String> = sqlx::query_scalar(
        "SELECT external_id FROM transactions \
         WHERE account_id = $1 AND user_id = $2 AND external_id = ANY($3)",
    )
    .bind(req.account_id)
    .bind(ctx.user_id)
    .bind(&sigs)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let existing: std::collections::HashSet<String> = existing.into_iter().collect();
    let duplicate_indices: Vec<usize> = sigs
        .iter()
        .enumerate()
        .filter(|(_, s)| existing.contains(*s))
        .map(|(i, _)| i)
        .collect();

    Json(serde_json::json!({ "duplicate_indices": duplicate_indices })).into_response()
}

/// GET /api/imports/continuity — per account, chain the stored running
/// balances across every imported statement and report likely-missing
/// months (a balance jump between sequential statements). Only considers
/// rows that carry both a `balance_after` and an `import_file`; Plaid-synced
/// rows and pre-`balance_after` imports are excluded.
async fn continuity_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let rows = sqlx::query(
        "SELECT a.id AS account_id, a.name AS account_name, \
                a.institution_name AS institution_name, \
                t.import_file AS import_file, t.date AS date, \
                t.amount AS amount, t.balance_after AS balance_after \
         FROM transactions t \
         JOIN accounts a ON a.id = t.account_id \
         WHERE t.user_id = $1 AND t.balance_after IS NOT NULL \
               AND t.import_file IS NOT NULL \
         ORDER BY a.id, t.date",
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // Group rows per account, preserving the (account-ordered) query order.
    struct Acct {
        name: String,
        institution: Option<String>,
        files: std::collections::HashSet<String>,
        rows: Vec<crate::services::continuity::Row>,
    }
    let mut order: Vec<Uuid> = Vec::new();
    let mut by_acct: HashMap<Uuid, Acct> = HashMap::new();
    for r in &rows {
        let id: Uuid = r.get("account_id");
        let acct = by_acct.entry(id).or_insert_with(|| {
            order.push(id);
            Acct {
                name: r.get("account_name"),
                institution: r.try_get("institution_name").ok(),
                files: std::collections::HashSet::new(),
                rows: Vec::new(),
            }
        });
        let file: String = r.get("import_file");
        acct.files.insert(file.clone());
        acct.rows.push(crate::services::continuity::Row {
            file,
            date: r.get("date"),
            amount: r.get("amount"),
            balance_after: r.try_get("balance_after").ok(),
        });
    }

    let accounts: Vec<serde_json::Value> = order
        .into_iter()
        .map(|id| {
            let a = &by_acct[&id];
            let warnings = crate::services::continuity::continuity_warnings(&a.rows);
            serde_json::json!({
                "account_id": id,
                "account_name": a.name,
                "institution_name": a.institution,
                "statement_count": a.files.len(),
                "warnings": warnings,
            })
        })
        .collect();

    Json(serde_json::json!({ "accounts": accounts })).into_response()
}

/// Snapshot of one in-flight upload. `terminal` becomes true once
/// the parse phase has produced a final state; the frontend uses
/// that to stop polling.
/// Per-file outcome, accumulated as each PDF finishes parsing so the
/// client can render a checklist (one row per file) rather than a bare
/// "N of M" counter. `count` is the number of transactions parsed (0 on
/// failure).
#[derive(Clone, Serialize)]
pub struct FileProgress {
    pub name: String,
    pub ok: bool,
    pub count: usize,
}

#[derive(Clone, Serialize)]
pub struct ProgressSnapshot {
    pub total: usize,
    pub done: usize,
    /// One entry per file that has finished parsing, in completion
    /// order. The client matches these against the files it submitted to
    /// drive a per-file checklist (✓ / skipped / still parsing).
    pub files: Vec<FileProgress>,
    /// True after the upload finished (success, password, or all-
    /// failed). Frontend stops polling once this flips.
    pub terminal: bool,
    /// Owner of the job. Set when the upload handler creates the
    /// entry; the polling endpoint refuses to return progress for a
    /// job owned by anyone other than the caller. Prevents one user
    /// from probing another user's upload state by guessing UUIDs.
    #[serde(skip_serializing)]
    pub owner: Uuid,
}

/// Module-level progress store. Lives for the process lifetime —
/// entries self-evict via a tokio::spawn at terminal-state time
/// (see `mark_terminal`). On process restart all in-flight uploads
/// would lose their progress entry; the upload itself would still
/// finish because the synchronous POST holds the full result.
fn progress_store() -> &'static Arc<RwLock<HashMap<Uuid, ProgressSnapshot>>> {
    static STORE: OnceLock<Arc<RwLock<HashMap<Uuid, ProgressSnapshot>>>> = OnceLock::new();
    STORE.get_or_init(|| Arc::new(RwLock::new(HashMap::new())))
}

/// Parse the optional `X-Upload-Job-Id` header. None means the
/// client isn't asking for progress (older clients, curl). We still
/// process the upload normally; the progress side-channel just
/// stays quiet.
fn parse_job_id(headers: &HeaderMap) -> Option<Uuid> {
    headers
        .get("x-upload-job-id")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| Uuid::parse_str(s.trim()).ok())
}

/// Register a fresh progress entry for the given job. Replaces any
/// existing entry (a client re-using a job-id has either crashed
/// and retried OR is deliberately overwriting — either way the
/// fresh-state semantics are right).
async fn register_job(job_id: Uuid, owner: Uuid, total: usize) {
    let store = progress_store();
    store.write().await.insert(
        job_id,
        ProgressSnapshot {
            total,
            done: 0,
            files: Vec::new(),
            terminal: false,
            owner,
        },
    );
}

/// Bump the done counter + append the completed file's outcome (name,
/// success, transaction count). Silent no-op when the job_id isn't
/// registered (older client).
async fn note_file_done(job_id: Uuid, name: String, ok: bool, count: usize) {
    let store = progress_store();
    if let Some(snap) = store.write().await.get_mut(&job_id) {
        snap.done += 1;
        snap.files.push(FileProgress { name, ok, count });
    }
}

/// Flip terminal=true and schedule the entry's eviction after a 30 s
/// grace window so the frontend's final poll still observes the
/// terminal flag.
async fn mark_terminal(job_id: Uuid) {
    let store = progress_store();
    if let Some(snap) = store.write().await.get_mut(&job_id) {
        snap.terminal = true;
    }
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        progress_store().write().await.remove(&job_id);
    });
}

/// GET /api/imports/progress/{job_id} — current snapshot for the
/// upload identified by `job_id`. 404 when the entry is missing
/// (either the upload finished + the grace window expired, or the
/// client polled with a bad id). 403 when the entry belongs to a
/// different user.
async fn progress_handler(
    Extension(ctx): Extension<AuthContext>,
    Path(job_id): Path<Uuid>,
) -> Response {
    let store = progress_store();
    let guard = store.read().await;
    match guard.get(&job_id) {
        Some(snap) if snap.owner == ctx.user_id => Json(snap.clone()).into_response(),
        Some(_) => StatusCode::FORBIDDEN.into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

/// A confirmed transaction plus the file it came from. `#[serde(flatten)]`
/// accepts the preview's flattened shape (ParsedTransaction fields +
/// `source_file`), so the per-row source survives into the persisted
/// import batch and can be shown / undone later.
#[derive(Deserialize)]
struct ConfirmTx {
    #[serde(flatten)]
    tx: ParsedTransaction,
    #[serde(default)]
    source_file: Option<String>,
}

#[derive(Deserialize)]
struct ConfirmRequest {
    account_id: uuid::Uuid,
    transactions: Vec<ConfirmTx>,
}

async fn confirm_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<ConfirmRequest>,
) -> axum::response::Response {
    let mut imported_count = 0;
    let mut duplicate_count = 0;
    // One batch id for this whole confirm, stamped on every inserted row so
    // the import can be listed + undone as a unit.
    let batch_id = uuid::Uuid::new_v4();

    // Currency-mismatch guard, scoped to caller's accounts so that an
    // attacker can't probe other users' account currencies via import
    // attempts. A foreign account id returns None → triggers the
    // standard "account not found" path below.
    let target_currency: Option<String> = match sqlx::query_scalar::<_, String>(
        "SELECT currency FROM accounts WHERE id = $1 AND user_id = $2",
    )
    .bind(payload.account_id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    {
        Ok(c) => c,
        Err(e) => {
            error!("Failed to look up target account currency: {}", e);
            None
        }
    };

    if target_currency.is_none() {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({
                "status": "error",
                "message": "Target account not found.",
            })),
        )
            .into_response();
    }

    if let Some(target_cur) = target_currency.as_deref() {
        let tx_currencies: std::collections::HashSet<String> = payload
            .transactions
            .iter()
            .map(|t| t.tx.currency.to_uppercase())
            .collect();
        if tx_currencies.len() == 1
            && !tx_currencies.contains(&target_cur.to_uppercase())
        {
            let tx_cur = tx_currencies.into_iter().next().unwrap();
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({
                    "status": "error",
                    "message": format!(
                        "All {} transactions are in {} but the selected account is in {}. Pick a {} account, or convert your statement.",
                        payload.transactions.len(), tx_cur, target_cur, tx_cur
                    ),
                })),
            )
                .into_response();
        }
    }

    // Statement continuity: every row in this confirm lands in ONE account,
    // so we can chain their per-statement running balances and flag a likely
    // missing statement (the gap month's balance jump). Computed before the
    // loop consumes `payload.transactions`. Advisory — returned in the
    // response, never blocks the import.
    let continuity_rows: Vec<crate::services::continuity::Row> = payload
        .transactions
        .iter()
        .map(|ct| crate::services::continuity::Row {
            file: ct.source_file.clone().unwrap_or_default(),
            date: ct.tx.date,
            amount: ct.tx.amount,
            balance_after: ct.tx.balance_after,
        })
        .collect();
    let continuity_warnings =
        crate::services::continuity::continuity_warnings(&continuity_rows);

    // Occurrence-aware external_ids: distinct same-day/same-amount/same-desc
    // rows get a `#N` suffix so the second isn't silently dropped, while the
    // first keeps the legacy bare signature (re-imports stay idempotent).
    // MUST match what check_duplicates computed for the preview.
    let signatures = batch_signatures(
        payload
            .transactions
            .iter()
            .map(|ct| (ct.tx.date, ct.tx.amount, ct.tx.description.clone())),
    );

    // Learn from edits: a map of the categories the user has manually
    // assigned (user_category), keyed by a coarse merchant key, so a
    // re-import inherits their own labeling instead of the generic rule
    // guess. Built once; most-recent edit wins per merchant.
    let learned: HashMap<String, String> = {
        let labeled = sqlx::query(
            "SELECT description, user_category FROM transactions \
             WHERE user_id = $1 AND user_category IS NOT NULL AND user_category <> '' \
             ORDER BY created_at DESC NULLS LAST",
        )
        .bind(ctx.user_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();
        let mut m: HashMap<String, String> = HashMap::new();
        for r in &labeled {
            let desc: String = r.get("description");
            let uc: String = r.get("user_category");
            let key = crate::services::categorize::merchant_key(&desc);
            if !key.is_empty() {
                m.entry(key).or_insert(uc); // DESC order → keep most recent
            }
        }
        m
    };

    // Closing balance = the running SALDO of the latest-dated row that
    // carries one (Banamex statements do). Used to set the account's
    // current balance after the import — idempotent on re-import.
    let mut closing: Option<(chrono::NaiveDate, rust_decimal::Decimal)> = None;

    for (i, ct) in payload.transactions.into_iter().enumerate() {
        let ConfirmTx { tx, source_file } = ct;
        if let Some(bal) = tx.balance_after {
            if closing.map(|(d, _)| tx.date >= d).unwrap_or(true) {
                closing = Some((tx.date, bal));
            }
        }
        let signature = &signatures[i];

        // Safety net: parse-time categorization already runs in
        // `polish_all`, but if the previewed tx round-tripped without a
        // category (older client, edited row), classify it here so the
        // ledger isn't left uncategorized.
        let basis = tx.original_description.clone().unwrap_or_else(|| tx.description.clone());
        let category = tx.category.clone().or_else(|| {
            crate::services::categorize::categorize(&basis, tx.amount)
        });
        // Learn-from-edits override: if the user has labeled this merchant
        // before, carry their label onto the new row (display prefers
        // user_category). Only on fresh inserts — the conflict path never
        // clobbers an existing manual edit.
        let user_category = {
            let key = crate::services::categorize::merchant_key(&basis);
            if key.is_empty() {
                None
            } else {
                learned.get(&key).cloned()
            }
        };

        // The parser stashes the pre-polish raw line in
        // `original_description` only when polish_description
        // meaningfully changed it. Persist verbatim so the
        // frontend's displayLabel ladder can fall back to it
        // ("DEPOSITO BANAMEX MERCH XYZ" → "BANAMEX MERCH XYZ" with
        // the original kept as the fallback). NULL when polishing
        // was a no-op — saves a column-equal-column copy.
        // ON CONFLICT DO UPDATE (rather than DO NOTHING) so a re-import
        // BACKFILLS balance_after onto rows imported before this column
        // existed — giving the full-history continuity check real data to
        // chain. COALESCE keeps any value already set. `RETURNING (xmax = 0)`
        // tells insert (true) from conflict-update (false) so the new-vs-
        // duplicate counts stay accurate despite the upsert.
        let result = sqlx::query(
            "INSERT INTO transactions (account_id, external_id, date, description, amount, currency, category, source, source_id, user_id, original_description, import_batch_id, import_file, balance_after, user_category)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'csv', $8, $9, $10, $11, $12, $13, $14)
             ON CONFLICT (account_id, external_id) DO UPDATE
                 SET balance_after = COALESCE(transactions.balance_after, EXCLUDED.balance_after)
             RETURNING (xmax = 0) AS inserted",
        )
        .bind(payload.account_id)
        .bind(signature.as_str())
        .bind(tx.date)
        .bind(&tx.description)
        .bind(tx.amount)
        .bind(&tx.currency)
        .bind(category)
        .bind("csv_import")
        .bind(ctx.user_id)
        .bind(tx.original_description.as_deref())
        .bind(batch_id)
        .bind(source_file.as_deref())
        .bind(tx.balance_after)
        .bind(user_category)
        .fetch_optional(&state.db)
        .await;

        match result {
            Ok(Some(row)) => {
                if row.try_get::<bool, _>("inserted").unwrap_or(true) {
                    imported_count += 1;
                } else {
                    duplicate_count += 1;
                }
            }
            Ok(None) => duplicate_count += 1,
            Err(e) => {
                error!("Failed to insert transaction: {}", e);
            }
        }
    }

    info!(
        "Import confirmation: {} new, {} duplicates for account {}",
        imported_count, duplicate_count, payload.account_id
    );

    // Set the account's current balance from the statement's closing
    // balance, so an imported account doesn't read $0. Idempotent: re-
    // importing the same (or newer) statements just re-sets it.
    if let Some((_, bal)) = closing {
        let _ = sqlx::query(
            "UPDATE accounts SET current_balance = $1, updated_at = NOW() \
             WHERE id = $2 AND user_id = $3",
        )
        .bind(bal)
        .bind(payload.account_id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await;
    }

    // Back-fill historical net-worth snapshots from the per-row running balance
    // (Banamex-style statements carry one). One snapshot per month — the last
    // balance of that month — so the net-worth chart reflects the imported
    // history instead of starting at onboarding. MXN is converted at the
    // current rate (an approximation for old months; no historical FX stored).
    // Accounts without a running balance (Cetes / Nu) yield no rows. Idempotent:
    // ON CONFLICT preserves any existing daily snapshot.
    let _ = sqlx::query(
        r#"
        WITH rate AS (
            SELECT rate FROM exchange_rates
            WHERE base_currency='USD' AND target_currency='MXN'
            ORDER BY recorded_at DESC LIMIT 1
        ),
        monthly AS (
            SELECT DISTINCT ON (date_trunc('month', t.date))
                   t.date AS d, t.balance_after AS bal
            FROM transactions t
            WHERE t.account_id = $1 AND t.user_id = $2 AND t.balance_after IS NOT NULL
            ORDER BY date_trunc('month', t.date), t.date DESC, t.id DESC
        )
        INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id)
        SELECT $1, m.bal, m.d, a.currency,
               CASE WHEN a.currency = 'MXN' AND r.rate IS NOT NULL AND r.rate <> 0
                    THEN ROUND(m.bal / r.rate, 2) ELSE m.bal END,
               $2
        FROM monthly m
        JOIN accounts a ON a.id = $1
        LEFT JOIN rate r ON TRUE
        ON CONFLICT (account_id, as_of_date) DO NOTHING
        "#,
    )
    .bind(payload.account_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    if imported_count > 0 || closing.is_some() {
        state
            .realtime
            .publish(
                ctx.user_id,
                crate::services::realtime::RealtimeEvent::TransactionsChanged,
            )
            .await;
        state
            .realtime
            .publish(
                ctx.user_id,
                crate::services::realtime::RealtimeEvent::AccountsChanged,
            )
            .await;
    }

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "success",
            "message": format!("Import complete: {} new transactions, {} duplicates found.", imported_count, duplicate_count),
            "new_transactions": imported_count,
            "duplicates": duplicate_count,
            // Only meaningful when something landed — used by "Undo import".
            "import_batch_id": if imported_count > 0 { Some(batch_id.to_string()) } else { None },
            // Advisory statement-continuity warnings (likely missing months).
            "warnings": continuity_warnings,
        })),
    )
        .into_response()
}

/// Accepts one OR many files in a single multipart request. A single
/// `password` field applies to every file in the batch (used by
/// encrypted PDFs).
///
/// Aggregation policy:
/// - If any file fails password decryption, surface `password_required`
///   immediately — the UI can re-prompt and retry the whole batch.
/// - Per-file parser errors are collected and ignored as long as at
///   least one file succeeded. The response message lists which files
///   failed so the user knows what got dropped.
/// - Only 422 when every file failed (and at least one error was real).
async fn upload_handler(
    State(_state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Response {
    let job_id = parse_job_id(&headers);
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();
    let mut password: Option<String> = None;

    loop {
        let field = match multipart.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => {
                error!("Multipart error: {:?}", e);
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ImportResponse {
                        message: format!("Failed to parse upload request: {}", e),
                        status: "error".to_string(),
                        transactions_count: 0,
                        transactions: vec![],
                        account_info: None,
                    }),
                )
                    .into_response();
            }
        };

        let name = field.name().unwrap_or("").to_string();
        if name == "password" {
            let pwd = field.text().await.unwrap_or_default();
            if !pwd.trim().is_empty() {
                password = Some(pwd);
            }
        } else if name == "file" || name == "files" || field.file_name().is_some() {
            let file_name = field.file_name().unwrap_or("unknown").to_string();
            let content_type = field
                .content_type()
                .map(|m| m.to_string())
                .unwrap_or_default();
            match field.bytes().await {
                Ok(bytes) => {
                    info!(
                        "Multipart field accepted: name='{}' content_type='{}' size={} bytes",
                        file_name,
                        content_type,
                        bytes.len()
                    );
                    files.push((file_name, bytes.to_vec()));
                }
                Err(e) => {
                    // Surface the file name + content-type the client
                    // sent so a future regression isn't "Failed to
                    // read file bytes" for the seventh time in a row
                    // with no idea which file was the problem.
                    error!(
                        "Failed to read multipart bytes for field name='{}' content_type='{}': {:?}",
                        file_name, content_type, e
                    );
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ImportResponse {
                            message: format!(
                                "Failed to read upload body for '{}'. \
                                 The browser may have aborted, or the body \
                                 exceeded the 100 MB cap. Detail: {}",
                                file_name, e
                            ),
                            status: "error".to_string(),
                            transactions_count: 0,
                            transactions: vec![],
                            account_info: None,
                        }),
                    )
                        .into_response();
                }
            }
        }
    }

    if files.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ImportResponse {
                message: "No files were found in the upload request.".to_string(),
                status: "error".to_string(),
                transactions_count: 0,
                transactions: vec![],
                account_info: None,
            }),
        )
            .into_response();
    }

    let total_files = files.len();

    // Per-file progress side-channel: when the client sent an
    // `X-Upload-Job-Id` header, register an entry in the progress
    // store so the parallel poller on /imports/progress/{job_id}
    // can report "N of M done · Last: foo.pdf" in real time. The
    // upload itself stays a single-shot synchronous response — the
    // earlier NDJSON streaming attempt caused ERR_CONNECTION_RESET
    // because the response started flushing while the upload body
    // was still arriving (Chromium aborts the POST in that case).
    if let Some(id) = job_id {
        register_job(id, ctx.user_id, total_files).await;
    }

    let mut all_transactions: Vec<PreviewTx> = Vec::new();
    let mut success_files: Vec<String> = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    // Password-failure signals can't early-return from the middle
    // of a parallel fan-out (the other tasks are running on the
    // blocking pool and can't be cancelled mid-parse). Collect
    // everything, then decide the response after the join phase.
    let mut password_state: Option<&'static str> = None;

    // Fan the parses out across the blocking pool so a batch of
    // 24 monthly PDFs doesn't run end-to-end at single-thread
    // speed. No explicit concurrency cap — the blocking pool
    // already bounds at 512 threads and the OS scheduler handles
    // CPU contention. Pathological inputs are blocked at the
    // DefaultBodyLimit layer above.
    let mut set: tokio::task::JoinSet<(
        String,
        anyhow::Result<Vec<ParsedTransaction>>,
        Option<parser::AccountInfo>,
    )> = tokio::task::JoinSet::new();
    for (file_name, file_data) in files {
        info!(
            "Queueing file for parse: {} ({} bytes)",
            file_name,
            file_data.len()
        );
        let pwd_owned = password.clone();
        let name_for_task = file_name.clone();
        set.spawn_blocking(move || {
            let result =
                parser::detect_and_parse(&name_for_task, &file_data, pwd_owned.as_deref());
            // Lift account-identifying metadata (CLABE, holder, suggested
            // balance/name) so the preview can pre-fill a new account.
            let info =
                parser::parse_account_info(&name_for_task, &file_data, pwd_owned.as_deref());
            (name_for_task, result, info)
        });
    }

    // The newest statement's account info wins (current balance, latest CLABE).
    let mut account_info: Option<parser::AccountInfo> = None;
    while let Some(join_result) = set.join_next().await {
        let (file_name, parse_result, info) = match join_result {
            Ok(triple) => triple,
            Err(e) => {
                error!("Parse task join failed: {}", e);
                errors.push(format!("internal join error: {}", e));
                continue;
            }
        };
        if let Some(info) = info {
            let newer = match (&account_info, &info.period_end) {
                (None, _) => true,
                (Some(cur), Some(end)) => cur
                    .period_end
                    .as_deref()
                    .map(|c| end.as_str() > c)
                    .unwrap_or(true),
                (Some(_), None) => false,
            };
            if newer {
                account_info = Some(info);
            }
        }
        let succeeded;
        let mut parsed_count = 0;
        match parse_result {
            Ok(txs) => {
                succeeded = true;
                parsed_count = txs.len();
                success_files.push(file_name.clone());
                // Tag every row with its source file for the preview.
                all_transactions.extend(txs.into_iter().map(|t| PreviewTx {
                    tx: t,
                    source_file: file_name.clone(),
                }));
            }
            Err(e) => {
                succeeded = false;
                let error_msg = e.to_string();
                if error_msg.contains("INCORRECT_PASSWORD") {
                    password_state = Some("incorrect");
                } else if error_msg.contains("PASSWORD_REQUIRED") {
                    // "incorrect" trumps "required" — if the user
                    // already supplied a password and it was wrong,
                    // that's the more accurate hint.
                    if password_state != Some("incorrect") {
                        password_state = Some("required");
                    }
                } else {
                    error!("Parser failed for {}: {}", file_name, error_msg);
                    errors.push(format!("{}: {}", file_name, error_msg));
                }
            }
        }
        if let Some(id) = job_id {
            note_file_done(id, file_name, succeeded, parsed_count).await;
        }
    }

    // Any password-required result short-circuits with the legacy
    // single-shot password_required response so the UI can re-prompt
    // and retry every file at once.
    if let Some(state) = password_state {
        let message = if state == "incorrect" {
            "The provided password was incorrect. Please try again."
        } else {
            "This statement is encrypted. Please enter your PDF password (e.g., your RFC) to unlock it."
        };
        if let Some(id) = job_id {
            mark_terminal(id).await;
        }
        return (
            StatusCode::OK,
            Json(ImportResponse {
                message: message.to_string(),
                status: "password_required".to_string(),
                transactions_count: 0,
                transactions: vec![],
                account_info: None,
            }),
        )
            .into_response();
    }

    info!(
        "Parsed {} transactions from {} of {} files",
        all_transactions.len(),
        success_files.len(),
        total_files,
    );

    // Every file failed — propagate the error in the response so
    // the frontend can show it. We keep HTTP 200 (the request
    // itself succeeded) and distinguish via the inner `status`
    // field, same contract callers were already coding against.
    let status_str = if all_transactions.is_empty() && !errors.is_empty() {
        "error"
    } else {
        "success"
    };

    let message = if errors.is_empty() {
        format!(
            "Successfully parsed {} transactions from {} file{}.",
            all_transactions.len(),
            success_files.len(),
            if success_files.len() == 1 { "" } else { "s" },
        )
    } else if all_transactions.is_empty() {
        format!("Processing Error: {}", errors.join("; "))
    } else {
        format!(
            "Parsed {} transactions from {} of {} files. Skipped: {}",
            all_transactions.len(),
            success_files.len(),
            total_files,
            errors.join("; "),
        )
    };

    let status_code = if status_str == "error" {
        StatusCode::UNPROCESSABLE_ENTITY
    } else {
        StatusCode::OK
    };

    if let Some(id) = job_id {
        mark_terminal(id).await;
    }

    (
        status_code,
        Json(ImportResponse {
            message,
            status: status_str.to_string(),
            transactions_count: all_transactions.len(),
            transactions: all_transactions,
            account_info,
        }),
    )
        .into_response()
}


// ---------- import cleanup ----------

/// GET /api/imports/batches — recent import batches (future imports, which
/// are tagged with a batch id), newest first, with the account, file(s),
/// row count, and date span. Used by the "Undo import" list.
async fn list_batches_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT t.import_batch_id,
               t.account_id,
               a.name AS account_name,
               COUNT(*) AS txn_count,
               MIN(t.date) AS from_date,
               MAX(t.date) AS to_date,
               MAX(t.created_at) AS imported_at,
               COALESCE(
                   ARRAY_AGG(DISTINCT t.import_file)
                       FILTER (WHERE t.import_file IS NOT NULL),
                   '{}'
               ) AS files
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.user_id = $1 AND t.import_batch_id IS NOT NULL
        GROUP BY t.import_batch_id, t.account_id, a.name
        ORDER BY MAX(t.created_at) DESC
        LIMIT 100
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let batches: Vec<serde_json::Value> = rows
        .iter()
        .map(|r| {
            serde_json::json!({
                "batch_id": r.try_get::<uuid::Uuid, _>("import_batch_id").map(|u| u.to_string()).unwrap_or_default(),
                "account_id": r.try_get::<uuid::Uuid, _>("account_id").map(|u| u.to_string()).unwrap_or_default(),
                "account_name": r.try_get::<String, _>("account_name").unwrap_or_default(),
                "txn_count": r.try_get::<i64, _>("txn_count").unwrap_or(0),
                "from_date": r.try_get::<chrono::NaiveDate, _>("from_date").map(|d| d.to_string()).unwrap_or_default(),
                "to_date": r.try_get::<chrono::NaiveDate, _>("to_date").map(|d| d.to_string()).unwrap_or_default(),
                "imported_at": r.try_get::<chrono::DateTime<chrono::Utc>, _>("imported_at").map(|d| d.to_rfc3339()).unwrap_or_default(),
                "files": r.try_get::<Vec<String>, _>("files").unwrap_or_default(),
            })
        })
        .collect();
    Json(serde_json::json!({ "batches": batches })).into_response()
}

/// DELETE /api/imports/batches/{id} — undo an import by deleting every row
/// it created (scoped to the caller).
async fn undo_batch_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<Uuid>,
) -> Response {
    let res = sqlx::query(
        "DELETE FROM transactions WHERE import_batch_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match res {
        Ok(r) => {
            if r.rows_affected() > 0 {
                state
                    .realtime
                    .publish(
                        ctx.user_id,
                        crate::services::realtime::RealtimeEvent::TransactionsChanged,
                    )
                    .await;
            }
            Json(serde_json::json!({ "deleted": r.rows_affected() })).into_response()
        }
        Err(e) => {
            error!("undo_batch failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct BulkDeleteRequest {
    account_id: uuid::Uuid,
    date_from: chrono::NaiveDate,
    date_to: chrono::NaiveDate,
    /// When true, only rows imported from a statement (`source_id =
    /// 'csv_import'`) are removed — leaves bank-synced transactions alone.
    #[serde(default)]
    imported_only: bool,
    /// When true, return the count that WOULD be deleted without deleting,
    /// for a confirm preview.
    #[serde(default)]
    dry_run: bool,
}

/// POST /api/imports/transactions/bulk-delete — remove transactions in an
/// account + inclusive date range (optionally only imported rows). The
/// cleanup path for PAST imports that predate batch tagging.
async fn bulk_delete_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(req): Json<BulkDeleteRequest>,
) -> Response {
    let owns: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2)",
    )
    .bind(req.account_id)
    .bind(ctx.user_id)
    .fetch_one(&state.db)
    .await
    .unwrap_or(false);
    if !owns {
        return StatusCode::NOT_FOUND.into_response();
    }

    if req.dry_run {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM transactions \
             WHERE user_id = $1 AND account_id = $2 AND date >= $3 AND date <= $4 \
               AND ($5 = false OR source_id = 'csv_import')",
        )
        .bind(ctx.user_id)
        .bind(req.account_id)
        .bind(req.date_from)
        .bind(req.date_to)
        .bind(req.imported_only)
        .fetch_one(&state.db)
        .await
        .unwrap_or(0);
        return Json(serde_json::json!({ "count": count })).into_response();
    }

    let res = sqlx::query(
        "DELETE FROM transactions \
         WHERE user_id = $1 AND account_id = $2 AND date >= $3 AND date <= $4 \
           AND ($5 = false OR source_id = 'csv_import')",
    )
    .bind(ctx.user_id)
    .bind(req.account_id)
    .bind(req.date_from)
    .bind(req.date_to)
    .bind(req.imported_only)
    .execute(&state.db)
    .await;
    match res {
        Ok(r) => {
            if r.rows_affected() > 0 {
                state
                    .realtime
                    .publish(
                        ctx.user_id,
                        crate::services::realtime::RealtimeEvent::TransactionsChanged,
                    )
                    .await;
            }
            Json(serde_json::json!({ "deleted": r.rows_affected() })).into_response()
        }
        Err(e) => {
            error!("bulk_delete failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use rust_decimal::Decimal;
    use std::str::FromStr;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }
    fn dec(s: &str) -> Decimal {
        Decimal::from_str(s).unwrap()
    }

    #[test]
    fn first_occurrence_keeps_the_legacy_bare_signature() {
        // Backward-compat: a lone row's signature is byte-identical to the
        // old scheme, so already-imported history still dedups.
        let date = d(2024, 3, 15);
        let amt = dec("-50.00");
        let sigs = batch_signatures([(date, amt, "COMPRA OXXO".to_string())]);
        assert_eq!(sigs, vec![tx_signature(&date, &amt, "COMPRA OXXO")]);
    }

    #[test]
    fn exact_duplicates_get_distinct_occurrence_suffixes() {
        // Two genuinely-distinct identical rows (e.g. two same-price coffees
        // the same day) must NOT collapse to one external_id.
        let date = d(2024, 3, 15);
        let amt = dec("-50.00");
        let sigs = batch_signatures(vec![
            (date, amt, "STARBUCKS".to_string()),
            (date, amt, "STARBUCKS".to_string()),
            (date, amt, "STARBUCKS".to_string()),
        ]);
        let base = tx_signature(&date, &amt, "STARBUCKS");
        assert_eq!(sigs, vec![base.clone(), format!("{base}#1"), format!("{base}#2")]);
        // All distinct → all three survive ON CONFLICT.
        let unique: std::collections::HashSet<_> = sigs.iter().collect();
        assert_eq!(unique.len(), 3);
    }

    #[test]
    fn distinct_rows_are_unaffected() {
        let sigs = batch_signatures(vec![
            (d(2024, 3, 15), dec("-50.00"), "OXXO".to_string()),
            (d(2024, 3, 16), dec("-50.00"), "OXXO".to_string()),
            (d(2024, 3, 15), dec("-51.00"), "OXXO".to_string()),
        ]);
        let unique: std::collections::HashSet<_> = sigs.iter().collect();
        assert_eq!(unique.len(), 3, "distinct rows keep distinct bare sigs");
    }
}
