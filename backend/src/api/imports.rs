use axum::{
    extract::{DefaultBodyLimit, Extension, Multipart, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use tokio::sync::RwLock;
use tracing::{error, info};
use uuid::Uuid;

use crate::api::session::AuthContext;
use crate::services::parser;
use crate::AppState;

use crate::models::import::{ConfirmImportRequest, ParsedTransaction};

#[derive(Serialize, Deserialize)]
pub struct ImportResponse {
    pub message: String,
    pub status: String,
    pub transactions_count: usize,
    pub transactions: Vec<ParsedTransaction>,
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

async fn confirm_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<ConfirmImportRequest>,
) -> axum::response::Response {
    let mut imported_count = 0;
    let mut duplicate_count = 0;

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
            .map(|t| t.currency.to_uppercase())
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

    for tx in payload.transactions {
        let signature = format!(
            "manual:{}:{}:{}",
            tx.date,
            tx.amount,
            tx.description
                .to_lowercase()
                .chars()
                .take(50)
                .collect::<String>()
        );

        // The parser stashes the pre-polish raw line in
        // `original_description` only when polish_description
        // meaningfully changed it. Persist verbatim so the
        // frontend's displayLabel ladder can fall back to it
        // ("DEPOSITO BANAMEX MERCH XYZ" → "BANAMEX MERCH XYZ" with
        // the original kept as the fallback). NULL when polishing
        // was a no-op — saves a column-equal-column copy.
        let result = sqlx::query(
            "INSERT INTO transactions (account_id, external_id, date, description, amount, currency, category, source, source_id, user_id, original_description)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'csv', $8, $9, $10)
             ON CONFLICT (account_id, external_id) DO NOTHING",
        )
        .bind(payload.account_id)
        .bind(&signature)
        .bind(tx.date)
        .bind(&tx.description)
        .bind(tx.amount)
        .bind(&tx.currency)
        .bind(tx.category)
        .bind("csv_import")
        .bind(ctx.user_id)
        .bind(tx.original_description.as_deref())
        .execute(&state.db)
        .await;

        match result {
            Ok(res) => {
                if res.rows_affected() > 0 {
                    imported_count += 1;
                } else {
                    duplicate_count += 1;
                }
            }
            Err(e) => {
                error!("Failed to insert transaction: {}", e);
            }
        }
    }

    info!(
        "Import confirmation: {} new, {} duplicates for account {}",
        imported_count, duplicate_count, payload.account_id
    );

    if imported_count > 0 {
        state
            .realtime
            .publish(
                ctx.user_id,
                crate::services::realtime::RealtimeEvent::TransactionsChanged,
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

    let mut all_transactions: Vec<ParsedTransaction> = Vec::new();
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
            (name_for_task, result)
        });
    }

    while let Some(join_result) = set.join_next().await {
        let (file_name, parse_result) = match join_result {
            Ok(pair) => pair,
            Err(e) => {
                error!("Parse task join failed: {}", e);
                errors.push(format!("internal join error: {}", e));
                continue;
            }
        };
        let succeeded;
        let mut parsed_count = 0;
        match parse_result {
            Ok(mut txs) => {
                succeeded = true;
                parsed_count = txs.len();
                success_files.push(file_name.clone());
                all_transactions.append(&mut txs);
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
        }),
    )
        .into_response()
}

