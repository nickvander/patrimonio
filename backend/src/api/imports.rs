use axum::{
    extract::{DefaultBodyLimit, Extension, Multipart, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use tracing::{error, info};

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

/// Stream of NDJSON events emitted by the `/upload` endpoint while
/// it parses the batch. The frontend reads chunked bytes, splits on
/// newline, parses each line as one of these variants, and renders
/// per-file progress between the user's click and the final result.
///
/// Old clients that don't speak the stream just keep reading until
/// the connection closes and look at the last line — the `done` /
/// `password_required` events carry the same shape as the legacy
/// single-shot `ImportResponse`, so a non-streaming client that
/// only parses the LAST JSON object still works.
#[derive(Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum ImportEvent {
    /// Sent first, before any parses start. `total` is the file
    /// count the client should compare per-file `done` events
    /// against to compute "N of M" progress.
    Started { total: usize },
    /// One per file. Emitted in the order parses complete (not the
    /// order they were submitted) — parallel parsing means the
    /// 8 MB statement may finish after the 2 MB one that was
    /// queued later.
    FileDone {
        name: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Terminal: at least one file is encrypted and we need the
    /// user to supply a password before retrying. Mirrors the
    /// legacy `status: "password_required"` response.
    PasswordRequired { message: String },
    /// Terminal: every file finished (some may have failed) and
    /// here is the aggregated result. Same shape as the legacy
    /// single-shot response — `transactions` is the concatenated
    /// list across every successful file.
    Done(ImportResponse),
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
        .route("/confirm", post(confirm_handler))
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

        let result = sqlx::query(
            "INSERT INTO transactions (account_id, external_id, date, description, amount, currency, category, source, source_id, user_id)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'csv', $8, $9)
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
    mut multipart: Multipart,
) -> Response {
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
            match field.bytes().await {
                Ok(bytes) => files.push((file_name, bytes.to_vec())),
                Err(e) => {
                    error!("Failed to read file bytes: {:?}", e);
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ImportResponse {
                            message: format!("Failed to read file data: {}", e),
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

    // Stream NDJSON events back to the client as parses complete.
    // The response body is an mpsc channel wrapped in a
    // `ReceiverStream` and handed to `axum::body::Body::from_stream`;
    // each parse completion produces a `file_done` event that the
    // frontend renders as "N of M done: foo.pdf". The legacy
    // single-shot response shape is preserved as the final `done`
    // event — clients that only parse the last line of the
    // response still get the original payload.
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);

    tokio::spawn(async move {
        // Serialize one event into a single NDJSON line and push it
        // through the channel. Returns false when the client has
        // dropped (best-effort short-circuit so we stop pulling
        // work for a request nobody is reading).
        async fn emit(
            tx: &tokio::sync::mpsc::Sender<Result<Bytes, std::io::Error>>,
            event: &ImportEvent,
        ) -> bool {
            let mut bytes = match serde_json::to_vec(event) {
                Ok(b) => b,
                Err(e) => {
                    error!("Failed to serialise import event: {}", e);
                    return false;
                }
            };
            bytes.push(b'\n');
            tx.send(Ok(Bytes::from(bytes))).await.is_ok()
        }

        if !emit(&tx, &ImportEvent::Started { total: total_files }).await {
            return;
        }

        let mut all_transactions: Vec<ParsedTransaction> = Vec::new();
        let mut success_files: Vec<String> = Vec::new();
        let mut errors: Vec<String> = Vec::new();
        // Password-failure signals can't early-return from the middle
        // of a parallel fan-out (the other tasks are running on the
        // blocking pool and can't be cancelled mid-parse). Collect
        // everything, then decide the terminal event after the join
        // phase.
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
                    let _ = emit(
                        &tx,
                        &ImportEvent::FileDone {
                            name: "(unknown)".to_string(),
                            ok: false,
                            error: Some(format!("internal join error: {}", e)),
                        },
                    )
                    .await;
                    continue;
                }
            };
            match parse_result {
                Ok(mut txs) => {
                    let _ = emit(
                        &tx,
                        &ImportEvent::FileDone {
                            name: file_name.clone(),
                            ok: true,
                            error: None,
                        },
                    )
                    .await;
                    success_files.push(file_name);
                    all_transactions.append(&mut txs);
                }
                Err(e) => {
                    let error_msg = e.to_string();
                    if error_msg.contains("INCORRECT_PASSWORD") {
                        password_state = Some("incorrect");
                    } else if error_msg.contains("PASSWORD_REQUIRED") {
                        // "incorrect" trumps "required" — if the
                        // user already supplied a password and it
                        // was wrong, that's the more accurate hint.
                        if password_state != Some("incorrect") {
                            password_state = Some("required");
                        }
                    } else {
                        error!("Parser failed for {}: {}", file_name, error_msg);
                        errors.push(format!("{}: {}", file_name, error_msg));
                    }
                    let _ = emit(
                        &tx,
                        &ImportEvent::FileDone {
                            name: file_name,
                            ok: false,
                            error: Some(error_msg),
                        },
                    )
                    .await;
                }
            }
        }

        // Any password-required result short-circuits with the
        // dedicated event so the UI can re-prompt + retry every
        // file at once.
        if let Some(state) = password_state {
            let message = if state == "incorrect" {
                "The provided password was incorrect. Please try again."
            } else {
                "This statement is encrypted. Please enter your PDF password (e.g., your RFC) to unlock it."
            };
            let _ = emit(
                &tx,
                &ImportEvent::PasswordRequired {
                    message: message.to_string(),
                },
            )
            .await;
            return;
        }

        info!(
            "Parsed {} transactions from {} of {} files",
            all_transactions.len(),
            success_files.len(),
            total_files,
        );

        // Every file failed — propagate the error in the terminal
        // event so the frontend can show it. Status stays at HTTP 200
        // (the stream itself succeeded); the client distinguishes
        // success from per-row failure via the `Done` event's inner
        // `status` field, same contract as the legacy response.
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

        let _ = emit(
            &tx,
            &ImportEvent::Done(ImportResponse {
                message,
                status: status_str.to_string(),
                transactions_count: all_transactions.len(),
                transactions: all_transactions,
            }),
        )
        .await;
    });

    let body = axum::body::Body::from_stream(
        tokio_stream::wrappers::ReceiverStream::new(rx),
    );

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/x-ndjson")
        .body(body)
        .unwrap()
}
