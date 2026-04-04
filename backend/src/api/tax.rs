use axum::{
    extract::{Query, State},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use csv::Writer;
use chrono::Datelike;
use crate::{AppState, services::tax::{TaxService, TaxEstimation}};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/summary", get(get_tax_summary))
        .route("/transactions", get(get_tax_transactions))
        .route("/export", get(export_tax_csv))
}

#[derive(Deserialize)]
struct TaxQuery {
    year: Option<i32>,
    status: Option<String>,
}

async fn get_tax_summary(
    State(state): State<AppState>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());
    let status = query.status.unwrap_or_else(|| "Single".to_string());

    match TaxService::calculate_yearly_tax(&state.db, year, &status).await {
        Ok(estimation) => Json::<TaxEstimation>(estimation).into_response(),
        Err(e) => {
            tracing::error!("Failed to calculate tax estimation: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": e.to_string() })),
            )
                .into_response()
        }
    }
}

async fn get_tax_transactions(
    State(state): State<AppState>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());

    match TaxService::get_taxable_transactions(&state.db, year).await {
        Ok(transactions) => Json::<Vec<crate::models::transaction::Transaction>>(transactions).into_response(),
        Err(e) => {
             tracing::error!("Failed to fetch taxable transactions: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": e.to_string() })),
            )
                .into_response()
        }
    }
}

async fn export_tax_csv(
     State(state): State<AppState>,
     Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());
    
    let transactions = match TaxService::get_taxable_transactions(&state.db, year).await {
        Ok(t) => t,
        Err(e) => {
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let mut wtr = Writer::from_writer(vec![]);
    
    // Header
    let _ = wtr.write_record(&["Date", "Description", "Amount", "Currency", "Category"]);

    for tx in transactions {
        let _ = wtr.write_record(&[
            tx.date.to_string(),
            tx.description,
            tx.amount.to_string(),
            tx.currency,
            tx.category.unwrap_or_default(),
        ]);
    }

    let csv_data = wtr.into_inner().unwrap_or_default();

    let mut headers = axum::http::HeaderMap::new();
    headers.insert(
        axum::http::header::CONTENT_TYPE,
        "text/csv".parse().unwrap(),
    );
    headers.insert(
        axum::http::header::CONTENT_DISPOSITION,
        format!("attachment; filename=\"tax_export_{}.csv\"", year).parse().unwrap(),
    );

    (headers, csv_data).into_response()
}
