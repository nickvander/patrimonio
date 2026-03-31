use axum::{
    extract::{Multipart, State, DefaultBodyLimit},
    http::StatusCode,
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tracing::{error, info};
use crate::AppState;
use crate::services::parser;

use crate::models::import::{ParsedTransaction, ConfirmImportRequest};

#[derive(Serialize, Deserialize)]
pub struct ImportResponse {
    pub message: String,
    pub status: String,
    pub transactions_count: usize,
    pub transactions: Vec<ParsedTransaction>,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/upload", post(upload_handler).layer(DefaultBodyLimit::max(20 * 1024 * 1024)))
        .route("/confirm", post(confirm_handler))
}

async fn confirm_handler(
    State(state): State<AppState>,
    Json(payload): Json<ConfirmImportRequest>,
) -> impl IntoResponse {
    let mut imported_count = 0;
    let mut duplicate_count = 0;

    for tx in payload.transactions {
        // Generate a deterministic signature for the external_id
        // Format: "manual:{date}:{amount}:{description_truncated}"
        let signature = format!(
            "manual:{}:{}:{}",
            tx.date,
            tx.amount,
            tx.description.to_lowercase().chars().take(50).collect::<String>()
        );

        let result = sqlx::query(
            "INSERT INTO transactions (account_id, external_id, date, description, amount, currency, category)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (account_id, external_id) DO NOTHING"
        )
        .bind(payload.account_id)
        .bind(&signature)
        .bind(tx.date)
        .bind(&tx.description)
        .bind(tx.amount)
        .bind(&tx.currency)
        .bind(tx.category)
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

    // Optional: Update account balance (sum of transactions is complex if there are existing ones)
    // For now, we just return the counts
    info!("Import confirmation: {} new, {} duplicates for account {}", imported_count, duplicate_count, payload.account_id);

    (StatusCode::OK, Json(serde_json::json!({
        "status": "success",
        "message": format!("Import complete: {} new transactions, {} duplicates found.", imported_count, duplicate_count),
        "new_transactions": imported_count,
        "duplicates": duplicate_count,
    })))
}

async fn upload_handler(
    State(_state): State<AppState>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let mut file_name = String::new();
    let mut file_data = Vec::new();
    let mut password = None;

    loop {
        let field_result = multipart.next_field().await;
        
        let field = match field_result {
            Ok(Some(f)) => f,
            Ok(None) => break, // End of multipart stream
            Err(e) => {
                error!("Multipart error: {:?}", e);
                return (StatusCode::BAD_REQUEST, Json(ImportResponse {
                    message: format!("Failed to parse upload request: {}", e),
                    status: "error".to_string(),
                    transactions_count: 0,
                    transactions: vec![],
                })).into_response();
            }
        };

        let name = field.name().unwrap_or("").to_string();
        if name == "password" {
            let pwd = field.text().await.unwrap_or_default();
            if !pwd.trim().is_empty() {
                password = Some(pwd);
            }
        } else if name == "file" || field.file_name().is_some() {
            file_name = field.file_name().unwrap_or("unknown").to_string();
            match field.bytes().await {
                Ok(bytes) => {
                    file_data = bytes.to_vec();
                }
                Err(e) => {
                    error!("Failed to read file bytes: {:?}", e);
                    return (StatusCode::BAD_REQUEST, Json(ImportResponse {
                        message: format!("Failed to read file data: {}", e),
                        status: "error".to_string(),
                        transactions_count: 0,
                        transactions: vec![],
                    })).into_response();
                }
            }
        }
    }

    if file_data.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(ImportResponse {
            message: "No file was found in the upload request. Please ensure you are uploading a valid statement.".to_string(),
            status: "error".to_string(),
            transactions_count: 0,
            transactions: vec![],
        })).into_response();
    }

    info!("Read {} bytes. Auto-detecting parser...", file_data.len());
    
    // Call auto-detection parser
    let transactions = match parser::detect_and_parse(&file_name, &file_data, password.as_deref()) {
        Ok(txs) => txs,
        Err(e) => {
            let error_msg = e.to_string();
            
            if error_msg.contains("PASSWORD_REQUIRED") {
                return (StatusCode::OK, Json(ImportResponse {
                    message: "This statement is encrypted. Please enter your PDF password (e.g., your RFC) to unlock it.".to_string(),
                    status: "password_required".to_string(),
                    transactions_count: 0,
                    transactions: vec![],
                })).into_response();
            }
            
            if error_msg.contains("INCORRECT_PASSWORD") {
                return (StatusCode::OK, Json(ImportResponse {
                    message: "The provided password was incorrect. Please try again.".to_string(),
                    status: "password_required".to_string(),
                    transactions_count: 0,
                    transactions: vec![],
                })).into_response();
            }

            error!("Parser failed for {}: {}", file_name, error_msg);
            return (StatusCode::UNPROCESSABLE_ENTITY, Json(ImportResponse {
                message: format!("Processing Error: {}", error_msg),
                status: "error".to_string(),
                transactions_count: 0,
                transactions: vec![],
            })).into_response();
        }
    };

    info!("Parsed {} transactions from {}", transactions.len(), file_name);
    
    (StatusCode::OK, Json(ImportResponse {
        message: format!("Successfully parsed {} transactions from {}", transactions.len(), file_name),
        status: "success".to_string(),
        transactions_count: transactions.len(),
        transactions,
    })).into_response()
}
