use axum::{
    extract::{DefaultBodyLimit, Multipart, State},
    http::StatusCode,
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

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
            post(upload_handler).layer(DefaultBodyLimit::max(20 * 1024 * 1024)),
        )
        .route("/confirm", post(confirm_handler))
}

async fn confirm_handler(
    State(state): State<AppState>,
    Json(payload): Json<ConfirmImportRequest>,
) -> axum::response::Response {
    let mut imported_count = 0;
    let mut duplicate_count = 0;

    // Guard against the "Banamex PDF imported into a Vanguard 401(k)" case
    // (which has actually happened). If every parsed transaction shares a
    // currency that doesn't match the target account's currency, refuse the
    // import and tell the user — there is no plausible reason to import
    // MXN bank statements into a USD brokerage.
    let target_currency: Option<String> = match sqlx::query_scalar::<_, String>(
        "SELECT currency FROM accounts WHERE id = $1",
    )
    .bind(payload.account_id)
    .fetch_optional(&state.db)
    .await
    {
        Ok(c) => c,
        Err(e) => {
            error!("Failed to look up target account currency: {}", e);
            None
        }
    };

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
            "INSERT INTO transactions (account_id, external_id, date, description, amount, currency, category, source, source_id)
             VALUES ($1, $2, $3, $4, $5, $6, $7, 'csv', $8)
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
) -> impl IntoResponse {
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
    let mut all_transactions: Vec<ParsedTransaction> = Vec::new();
    let mut success_files: Vec<String> = Vec::new();
    let mut errors: Vec<String> = Vec::new();

    for (file_name, file_data) in files {
        info!(
            "Processing file: {} ({} bytes)",
            file_name,
            file_data.len()
        );
        // detect_and_parse runs qpdf + lopdf synchronously, both of
        // which are CPU- and disk-bound and would block the tokio
        // worker for the duration of the parse. spawn_blocking moves
        // it to the dedicated blocking pool so other requests keep
        // making progress.
        let file_name_clone = file_name.clone();
        let pwd_owned = password.clone();
        let result = tokio::task::spawn_blocking(move || {
            parser::detect_and_parse(&file_name_clone, &file_data, pwd_owned.as_deref())
        })
        .await
        .map_err(|e| anyhow::anyhow!("parse task join: {}", e))
        .and_then(|r| r);
        match result {
            Ok(mut txs) => {
                success_files.push(file_name);
                all_transactions.append(&mut txs);
            }
            Err(e) => {
                let error_msg = e.to_string();
                // Password issues abort the whole batch: the UI must
                // re-prompt and we retry every file with the new
                // password. Mixing successful + password_required
                // files would be confusing.
                if error_msg.contains("PASSWORD_REQUIRED") {
                    return (
                        StatusCode::OK,
                        Json(ImportResponse {
                            message: "This statement is encrypted. Please enter your PDF password (e.g., your RFC) to unlock it.".to_string(),
                            status: "password_required".to_string(),
                            transactions_count: 0,
                            transactions: vec![],
                        }),
                    )
                        .into_response();
                }
                if error_msg.contains("INCORRECT_PASSWORD") {
                    return (
                        StatusCode::OK,
                        Json(ImportResponse {
                            message: "The provided password was incorrect. Please try again.".to_string(),
                            status: "password_required".to_string(),
                            transactions_count: 0,
                            transactions: vec![],
                        }),
                    )
                        .into_response();
                }
                error!("Parser failed for {}: {}", file_name, error_msg);
                errors.push(format!("{}: {}", file_name, error_msg));
            }
        }
    }

    // Every file failed — propagate the error so the user can fix it.
    if all_transactions.is_empty() && !errors.is_empty() {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(ImportResponse {
                message: format!("Processing Error: {}", errors.join("; ")),
                status: "error".to_string(),
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

    let message = if errors.is_empty() {
        format!(
            "Successfully parsed {} transactions from {} file{}.",
            all_transactions.len(),
            success_files.len(),
            if success_files.len() == 1 { "" } else { "s" },
        )
    } else {
        format!(
            "Parsed {} transactions from {} of {} files. Skipped: {}",
            all_transactions.len(),
            success_files.len(),
            total_files,
            errors.join("; "),
        )
    };

    (
        StatusCode::OK,
        Json(ImportResponse {
            message,
            status: "success".to_string(),
            transactions_count: all_transactions.len(),
            transactions: all_transactions,
        }),
    )
        .into_response()
}
