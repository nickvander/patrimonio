use axum::{
    extract::{Extension, Query, State},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use csv::WriterBuilder;
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
    let status = query.status.unwrap_or_else(|| "Single".to_string());

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
    // Realized-gains detail + summary. Best-effort: a failure here shouldn't
    // sink the whole export — the income-transaction section still ships.
    let disposals = TaxService::get_lot_disposals(&state.db, year, ctx.user_id)
        .await
        .unwrap_or_default();
    let estimation =
        TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id)
            .await
            .ok();

    // Records vary in width (section headers vs data rows), so the writer must
    // run in flexible mode — the default errors on inconsistent field counts.
    let mut wtr = WriterBuilder::new().flexible(true).from_writer(vec![]);
    let money = |d: rust_decimal::Decimal| d.round_dp(2).to_string();

    let _ = wtr.write_record(["Patrimonio tax export", &year.to_string()]);
    let _ = wtr.write_record(["Filing status", &status]);
    let _ = wtr.write_record([""; 0]);

    // Section 1 — taxable income transactions.
    let _ = wtr.write_record(["Taxable income transactions"]);
    let _ = wtr.write_record(["Date", "Description", "Amount", "Currency", "Category"]);
    for tx in transactions {
        let _ = wtr.write_record([
            tx.date.to_string(),
            tx.description,
            tx.amount.to_string(),
            tx.currency,
            tx.category.unwrap_or_default(),
        ]);
    }
    let _ = wtr.write_record([""; 0]);

    // Section 2 — realized capital gains (Form 8949 style), one row per lot
    // disposal, split short/long-term. Tax-advantaged-account disposals are
    // NOT taxable events, so they're kept out of the 8949 section and listed
    // in their own labeled section below instead.
    let term_label = |lt: Option<bool>| match lt {
        Some(true) => "Long-term",
        Some(false) => "Short-term",
        None => "Unknown",
    };
    let _ = wtr.write_record(["Realized capital gains (lot disposals)"]);
    let _ = wtr.write_record([
        "Symbol",
        "Name",
        "Date acquired",
        "Date sold",
        "Term",
        "Quantity",
        "Proceeds (USD)",
        "Cost basis (USD)",
        "Gain/loss (USD)",
    ]);
    for d in disposals.iter().filter(|d| !d.tax_advantaged) {
        let _ = wtr.write_record([
            d.symbol.clone(),
            d.name.clone(),
            d.acquired_date.clone().unwrap_or_default(),
            d.sell_date.clone(),
            term_label(d.long_term).to_string(),
            d.qty_sold.normalize().to_string(),
            money(d.proceeds_usd),
            money(d.cost_usd),
            money(d.gain_usd),
        ]);
    }
    let _ = wtr.write_record([""; 0]);

    // Section 2b — the excluded tax-advantaged activity, visible rather than
    // silently dropped. Only written when there is any.
    if disposals.iter().any(|d| d.tax_advantaged) {
        let _ = wtr.write_record([
            "Tax-advantaged account disposals (excluded from taxable gains)",
        ]);
        let _ = wtr.write_record([
            "Symbol",
            "Name",
            "Account type",
            "Date acquired",
            "Date sold",
            "Term",
            "Quantity",
            "Proceeds (USD)",
            "Cost basis (USD)",
            "Gain/loss (USD)",
        ]);
        for d in disposals.iter().filter(|d| d.tax_advantaged) {
            let _ = wtr.write_record([
                d.symbol.clone(),
                d.name.clone(),
                d.account_type.clone().unwrap_or_default(),
                d.acquired_date.clone().unwrap_or_default(),
                d.sell_date.clone(),
                term_label(d.long_term).to_string(),
                d.qty_sold.normalize().to_string(),
                money(d.proceeds_usd),
                money(d.cost_usd),
                money(d.gain_usd),
            ]);
        }
        let _ = wtr.write_record([""; 0]);
    }

    // Section 3 — summary (incl. the ST/LT split that feeds the liability).
    let _ = wtr.write_record(["Summary"]);
    if let Some(est) = &estimation {
        let _ = wtr.write_record(["Short-term gains (USD)", &money(est.short_term_gains)]);
        let _ = wtr.write_record(["Long-term gains (USD)", &money(est.long_term_gains)]);
        let _ = wtr.write_record(["Total capital gains (USD)", &money(est.capital_gains)]);
        let _ = wtr.write_record([
            "Tax-advantaged gains, excluded (USD)",
            &money(est.tax_advantaged_gains),
        ]);
        let _ = wtr.write_record(["Ordinary income (USD)", &money(est.ordinary_income)]);
        let _ = wtr.write_record(["Total taxable (USD)", &money(est.total_taxable)]);
        let _ = wtr.write_record([
            "Estimated liability — US IRS (USD)",
            &money(est.estimated_liability_us),
        ]);
        let _ = wtr.write_record([
            "Estimated liability — MX SAT (USD)",
            &money(est.estimated_liability_mx),
        ]);
        let basis = if est.gains_from_lots {
            "Precise lot disposals"
        } else {
            "No lot disposals on file"
        };
        let _ = wtr.write_record(["Capital-gains basis", basis]);
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

    // Build the text lines with a descending y-cursor so adding/removing a
    // line (e.g. the conditional ST/LT split) doesn't mean re-tuning every
    // absolute coordinate below it.
    let mut ops: Vec<Operation> = Vec::new();
    let mut y = 750i64;
    let line = |ops: &mut Vec<Operation>, y: &mut i64, size: i64, indent: i64, text: String| {
        ops.push(Operation::new("BT", vec![]));
        ops.push(Operation::new("Tf", vec!["F1".into(), size.into()]));
        ops.push(Operation::new("Td", vec![(50 + indent).into(), (*y).into()]));
        ops.push(Operation::new("Tj", vec![Object::string_literal(text)]));
        ops.push(Operation::new("ET", vec![]));
        *y -= if size >= 20 { 40 } else { 22 };
    };

    line(&mut ops, &mut y, 20, 0, format!("Patrimonio Tax Summary - {}", year));
    line(&mut ops, &mut y, 12, 0, format!("Filing Status: {}", status));
    y -= 8; // small gap before the figures
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!("Ordinary Income: ${}", estimation.ordinary_income.round_dp(2)),
    );
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!("Capital Gains: ${}", estimation.capital_gains.round_dp(2)),
    );
    // Short/long-term breakdown behind the capital-gains figure. Indented so
    // it reads as a sub-detail of the line above.
    let basis_note = if estimation.gains_from_lots {
        "from lot disposals"
    } else {
        "no lot disposals on file"
    };
    line(
        &mut ops,
        &mut y,
        11,
        20,
        format!(
            "Short-term (ordinary rates): ${}",
            estimation.short_term_gains.round_dp(2)
        ),
    );
    line(
        &mut ops,
        &mut y,
        11,
        20,
        format!(
            "Long-term (preferential rates): ${}  [{}]",
            estimation.long_term_gains.round_dp(2),
            basis_note
        ),
    );
    // Activity inside 401k/IRA/HSA-style wrappers is excluded from the
    // taxable figures above — shown so it isn't silently hidden.
    if estimation.tax_advantaged_gains != rust_decimal::Decimal::ZERO {
        line(
            &mut ops,
            &mut y,
            11,
            20,
            format!(
                "Tax-advantaged accounts (excluded): ${}",
                estimation.tax_advantaged_gains.round_dp(2)
            ),
        );
    }
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!("Total Taxable Amount: ${}", estimation.total_taxable.round_dp(2)),
    );
    y -= 8;
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!(
            "Estimated Liability (US IRS): ${}",
            estimation.estimated_liability_us.round_dp(2)
        ),
    );
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!(
            "Estimated Liability (MX SAT): ${}",
            estimation.estimated_liability_mx.round_dp(2)
        ),
    );

    let content = Content { operations: ops };

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
