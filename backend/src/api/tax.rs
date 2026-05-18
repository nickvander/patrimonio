use axum::{
    extract::{Extension, Query, State},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use csv::Writer;
use chrono::Datelike;
use crate::api::session::AuthContext;
use crate::{AppState, services::tax::{TaxService, TaxEstimation}};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/summary", get(get_tax_summary))
        .route("/transactions", get(get_tax_transactions))
        .route("/export", get(export_tax_csv))
        .route("/export/pdf", get(export_tax_pdf))
}

#[derive(Deserialize)]
struct TaxQuery {
    year: Option<i32>,
    status: Option<String>,
}

async fn get_tax_summary(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());
    let status = query.status.unwrap_or_else(|| "Single".to_string());

    match TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id).await {
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
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());

    match TaxService::get_taxable_transactions(&state.db, year, ctx.user_id).await {
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
     Extension(ctx): Extension<AuthContext>,
     Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());

    let transactions = match TaxService::get_taxable_transactions(&state.db, year, ctx.user_id).await {
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

async fn export_tax_pdf(
     State(state): State<AppState>,
     Extension(ctx): Extension<AuthContext>,
     Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = query.year.unwrap_or_else(|| chrono::Utc::now().naive_utc().year());
    let status = query.status.unwrap_or_else(|| "Single".to_string());

    let estimation = match TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id).await {
        Ok(est) => est,
        Err(e) => {
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": e.to_string() })),
            ).into_response();
        }
    };

    use lopdf::{Document, Object, dictionary};
    use lopdf::content::{Content, Operation};

    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "Type1",
        "BaseFont" => "Helvetica",
    });
    let resources_id = doc.add_object(dictionary! {
        "Font" => dictionary! {
            "F1" => font_id,
        },
    });

    let content = Content {
        operations: vec![
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 20.into()]),
            Operation::new("Td", vec![50.into(), 750.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Patrimonio Tax Summary - {}", year))]),
            Operation::new("ET", vec![]),
            
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![50.into(), 700.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Filing Status: {}", status))]),
            Operation::new("ET", vec![]),
            
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![50.into(), 660.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Ordinary Income: ${}", estimation.ordinary_income.round_dp(2)))]),
            Operation::new("ET", vec![]),

            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![50.into(), 640.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Capital Gains: ${}", estimation.capital_gains.round_dp(2)))]),
            Operation::new("ET", vec![]),
            
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![50.into(), 620.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Total Taxable Amount: ${}", estimation.total_taxable.round_dp(2)))]),
            Operation::new("ET", vec![]),

            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![50.into(), 580.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Estimated Liability (US IRS): ${}", estimation.estimated_liability_us.round_dp(2)))]),
            Operation::new("ET", vec![]),
            
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![50.into(), 560.into()]),
            Operation::new("Tj", vec![Object::string_literal(format!("Estimated Liability (MX SAT): ${}", estimation.estimated_liability_mx.round_dp(2)))]),
            Operation::new("ET", vec![]),
        ],
    };

    let content_id = doc.add_object(lopdf::Stream::new(dictionary! {}, content.encode().unwrap()));
    let page_id = doc.add_object(dictionary! {
        "Type" => "Page",
        "Parent" => pages_id,
        "Contents" => content_id,
        "Resources" => resources_id,
        "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
    });

    let pages = dictionary! {
        "Type" => "Pages",
        "Kids" => vec![page_id.into()],
        "Count" => 1,
    };
    doc.objects.insert(pages_id, Object::Dictionary(pages));
    let catalog_id = doc.add_object(dictionary! {
        "Type" => "Catalog",
        "Pages" => pages_id,
    });
    doc.trailer.set("Root", catalog_id);
    doc.compress();
    
    let mut pdf_bytes = Vec::new();
    let _ = doc.save_to(&mut pdf_bytes);

    let mut headers = axum::http::HeaderMap::new();
    headers.insert(
        axum::http::header::CONTENT_TYPE,
        "application/pdf".parse().unwrap(),
    );
    headers.insert(
        axum::http::header::CONTENT_DISPOSITION,
        format!("attachment; filename=\"tax_summary_{}.pdf\"", year).parse().unwrap(),
    );

    (headers, pdf_bytes).into_response()
}
