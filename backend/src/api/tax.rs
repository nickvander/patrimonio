use crate::api::error::ApiError;
use crate::api::middleware::AuthContext;
use crate::{
    services::tax::{TaxEstimation, TaxService},
    AppState,
};
use axum::{
    extract::{Extension, Query, State},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use chrono::Datelike;
use csv::WriterBuilder;
use serde::Deserialize;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/summary", get(get_tax_summary))
        .route("/transactions", get(get_tax_transactions))
        .route("/disposals", get(get_tax_disposals))
        .route("/unrealized", get(get_tax_unrealized))
        .route("/fbar", get(get_fbar_status))
        .route("/contributions", get(get_retirement_contributions))
        .route("/export", get(export_tax_csv))
        .route("/export/pdf", get(export_tax_pdf))
        // Tax-filing export pack (FBAR worksheet, 8949 / Schedule B / MX
        // CSVs) — merged here so the routes share this router's mount point
        // (and therefore the auth stack and the integration-test harness).
        .merge(crate::api::tax_exports::router())
}

#[derive(Deserialize)]
struct TaxQuery {
    year: Option<i32>,
    status: Option<String>,
}

/// Range of `?year=` values the tax endpoints accept.
///
/// The bound that matters is chrono's: `NaiveDate::from_ymd_opt` returns
/// `None` outside roughly ±262143, and every tax computation calls it as
/// `from_ymd_opt(year, 1, 1).unwrap()` (services/tax.rs:1032 and seven
/// siblings). `GET /api/tax/summary?year=300000` therefore PANICKED inside
/// the handler — with no `CatchPanicLayer` mounted that aborted the
/// connection, so the client saw a dropped request rather than any status
/// code, and the panic was reachable by any authenticated user.
///
/// The window is deliberately much tighter than chrono's: these endpoints
/// read `transactions`/`balance_snapshots` for a filing year, so anything
/// outside a plausible human tax range is a typo or a probe, and answering
/// with 400 is more useful than an empty 200.
pub(crate) const MIN_TAX_YEAR: i32 = 1900;
pub(crate) const MAX_TAX_YEAR: i32 = 2200;

impl TaxQuery {
    /// The requested year, defaulting to the current one, rejected with 400
    /// when out of range. Every handler must go through this — calling
    /// `from_ymd_opt(...).unwrap()` on an unvalidated `?year=` is the panic
    /// described on [`MIN_TAX_YEAR`].
    fn resolved_year(&self) -> Result<i32, ApiError> {
        let year = self
            .year
            .unwrap_or_else(|| chrono::Utc::now().naive_utc().year());
        if !(MIN_TAX_YEAR..=MAX_TAX_YEAR).contains(&year) {
            return Err(ApiError::new(
                axum::http::StatusCode::BAD_REQUEST,
                &format!("year must be between {MIN_TAX_YEAR} and {MAX_TAX_YEAR}"),
            ));
        }
        Ok(year)
    }
}

/// The setting key under which the frontend persists the user's filing
/// status (via `PUT /settings/{key}`). When a tax endpoint is hit without an
/// explicit `status` query param — e.g. a direct CSV/PDF link, or a fresh
/// page load before the screen has wired its dropdown — the backend honors
/// this persisted value as the default. Stays in lockstep with the key the
/// frontend writes.
const FILING_STATUS_SETTING_KEY: &str = "tax_filing_status";

/// Resolve the filing status for a request the same way for every tax
/// endpoint: an explicit query param wins; otherwise fall back to the user's
/// persisted `tax_filing_status` setting; otherwise the hardcoded default
/// (Single). The returned string is normalized to the vocabulary the bracket
/// tables key on (`Single` / `Married` / `Head of Household`) — anything else
/// (including a stale or malformed persisted value) collapses to `Single`,
/// matching `TaxYearTables::us_status`'s own fall-through.
pub(crate) async fn resolve_filing_status(
    state: &AppState,
    user_id: uuid::Uuid,
    query_status: Option<String>,
) -> String {
    let raw = match query_status {
        Some(s) => Some(s),
        None => sqlx::query_scalar::<_, serde_json::Value>(
            "SELECT value FROM app_settings WHERE key = $1 AND user_id = $2",
        )
        .bind(FILING_STATUS_SETTING_KEY)
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten()
        // The setting stores a JSON string; ignore null / non-string shapes.
        .and_then(|v| v.as_str().map(|s| s.to_string())),
    };
    normalize_filing_status(raw.as_deref())
}

/// Map any incoming status string onto the canonical vocabulary the year
/// tables understand; unknown / absent → `Single` (same default the service
/// layer applies). Case- and whitespace-insensitive so a persisted value or a
/// query param doesn't have to be character-perfect.
fn normalize_filing_status(raw: Option<&str>) -> String {
    match raw.map(|s| s.trim().to_lowercase()).as_deref() {
        Some("married") => "Married".to_string(),
        Some("head of household") => "Head of Household".to_string(),
        _ => "Single".to_string(),
    }
}

async fn get_tax_summary(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };
    let status = resolve_filing_status(&state, ctx.user_id, query.status).await;

    match TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id).await {
        Ok(estimation) => Json::<TaxEstimation>(estimation).into_response(),
        Err(e) => {
            tracing::error!("Failed to calculate tax estimation: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                // Generic message to the client; the real error is logged
                // via tracing::error! above (§1: never leak internals on a 500).
                Json(serde_json::json!({ "error": "Internal server error" })),
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
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };

    match TaxService::get_taxable_transactions(&state.db, year, ctx.user_id).await {
        Ok(transactions) => {
            Json::<Vec<crate::services::tax::TaxableTransaction>>(transactions).into_response()
        }
        Err(e) => {
            tracing::error!("Failed to fetch taxable transactions: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                // Generic message to the client; the real error is logged
                // via tracing::error! above (§1: never leak internals on a 500).
                Json(serde_json::json!({ "error": "Internal server error" })),
            )
                .into_response()
        }
    }
}

/// T7: the realized-capital-gains detail behind the summary's ST/LT figures,
/// as JSON. Same source query (and the same tax-advantaged flagging) the CSV's
/// 8949 section uses — but here BOTH taxable and tax-advantaged disposals are
/// returned, each carrying its `tax_advantaged` flag so the screen can split
/// or badge them itself. Newest `sell_date` first (the service query returns
/// ascending, so reverse here without disturbing the CSV's ordering).
async fn get_tax_disposals(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };

    match TaxService::get_lot_disposals(&state.db, year, ctx.user_id).await {
        Ok(mut disposals) => {
            disposals.reverse();
            Json::<Vec<crate::services::tax::TaxDisposal>>(disposals).into_response()
        }
        Err(e) => {
            tracing::error!("Failed to fetch lot disposals: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                // Generic message to the client; the real error is logged
                // via tracing::error! above (§1: never leak internals on a 500).
                Json(serde_json::json!({ "error": "Internal server error" })),
            )
                .into_response()
        }
    }
}

/// T11: the unrealized per-lot "what if I sell" view for TAXABLE accounts —
/// per-lot signed USD gain/loss, ST/LT term with days-until-long-term, and
/// loss-harvest candidates with an estimated marginal-rate tax saving and a
/// forward-looking wash-sale guard (T12). The marginal rates and savings ride
/// the UNVERIFIED constant tables, so the response carries `constants_verified`
/// for the UI to badge. Filing status is resolved like the other endpoints
/// (query param > persisted setting > Single), since the marginal rate is
/// status-dependent. Loss harvesting is evaluated as of today (the FX rate for
/// valuing live prices and the wash-sale window are both anchored at today).
async fn get_tax_unrealized(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };
    let status = resolve_filing_status(&state, ctx.user_id, query.status).await;
    let today = chrono::Utc::now().naive_utc().date();

    match TaxService::get_unrealized_lots(&state.db, year, &status, ctx.user_id, today).await {
        Ok(unrealized) => Json::<crate::services::tax::UnrealizedLots>(unrealized).into_response(),
        Err(e) => {
            tracing::error!("Failed to compute unrealized lots: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                // Generic message to the client; the real error is logged
                // via tracing::error! above (§1: never leak internals on a 500).
                Json(serde_json::json!({ "error": "Internal server error" })),
            )
                .into_response()
        }
    }
}

/// T13: FBAR/FATCA threshold monitor for the year — the MAX over the year of
/// the daily aggregate USD balance across FOREIGN accounts (institution
/// country <> US, or MXN currency), the $10,000 threshold (gated UNVERIFIED
/// via `constants_verified`), an `exceeded` flag, the peak date, and the
/// foreign accounts involved with each one's peak-date contribution + YTD max.
/// INFORMATIONAL ONLY — does not decide a filing obligation and does not
/// compute FATCA Form 8938 (different, higher thresholds). Empty case (no
/// foreign accounts / no snapshots) returns `exceeded = false`, peak 0, no
/// peak date, empty account list.
async fn get_fbar_status(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };

    match TaxService::fbar_status(&state.db, year, ctx.user_id).await {
        Ok(status) => Json::<crate::services::tax::FbarStatus>(status).into_response(),
        Err(e) => {
            tracing::error!("Failed to compute FBAR status: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                // Generic message to the client; the real error is logged
                // via tracing::error! above (§1: never leak internals on a 500).
                Json(serde_json::json!({ "error": "Internal server error" })),
            )
                .into_response()
        }
    }
}

/// T15: YTD retirement contributions vs annual limits, per account-type group
/// (401k-family, IRA traditional+Roth aggregate, HSA). Each group carries its
/// YTD contributions, the year's (UNVERIFIED) base limit + catch-up, remaining
/// room, the contribution deadline (IRA/HSA prior-year window vs 401k
/// calendar-year end), and a `match_rollover_caveat` flag when employer
/// match / rollovers can't be separated. The limits ride the UNVERIFIED
/// constant tables, so the response carries `constants_verified` for the UI to
/// badge.
async fn get_retirement_contributions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };

    match TaxService::retirement_contributions(&state.db, year, ctx.user_id).await {
        Ok(contributions) => {
            Json::<crate::services::tax::RetirementContributions>(contributions).into_response()
        }
        Err(e) => {
            tracing::error!("Failed to compute retirement contributions: {}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                // Generic message to the client; the real error is logged
                // via tracing::error! above (§1: never leak internals on a 500).
                Json(serde_json::json!({ "error": "Internal server error" })),
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
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };
    let status = resolve_filing_status(&state, ctx.user_id, query.status).await;

    let transactions =
        match TaxService::get_taxable_transactions(&state.db, year, ctx.user_id).await {
            Ok(t) => t,
            Err(e) => {
                tracing::error!("Failed to fetch taxable transactions (export): {}", e);
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    // Generic message to the client; the real error is logged
                    // via tracing::error! above (§1: never leak internals on a 500).
                    Json(serde_json::json!({ "error": "Internal server error" })),
                )
                    .into_response();
            }
        };
    // Realized-gains detail + summary. Best-effort: a failure here shouldn't
    // sink the whole export — the income-transaction section still ships.
    let disposals = TaxService::get_lot_disposals(&state.db, year, ctx.user_id)
        .await
        .unwrap_or_default();
    let estimation = TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id)
        .await
        .ok();

    // Records vary in width (section headers vs data rows), so the writer must
    // run in flexible mode — the default errors on inconsistent field counts.
    let mut wtr = WriterBuilder::new().flexible(true).from_writer(vec![]);
    // Always 2 decimals: `round_dp(2).to_string()` left zero/whole values as
    // "0" while non-zero showed "0.00", giving an inconsistent CSV column.
    let money = |d: rust_decimal::Decimal| format!("{d:.2}");

    let _ = wtr.write_record(["Patrimonio tax export", &year.to_string()]);
    let _ = wtr.write_record(["Filing status", &status]);
    let _ = wtr.write_record([""; 0]);

    // Section 1 — taxable income transactions. "Amount (native)" is the
    // stored amount in the row's own currency; "Amount (USD)" is that amount
    // converted at the transaction date's USD/MXN rate — the same per-row
    // conversion the summary's ordinary-income figure is built from, so this
    // column totals to the summary line below.
    let _ = wtr.write_record(["Taxable income transactions"]);
    let _ = wtr.write_record([
        "Date",
        "Description",
        "Amount (native)",
        "Currency",
        "Amount (USD)",
        "Category",
    ]);
    for tx in transactions {
        let _ = wtr.write_record([
            tx.tx.date.to_string(),
            tx.tx.description,
            tx.tx.amount.to_string(),
            tx.tx.currency,
            money(tx.amount_usd),
            tx.tx.category.unwrap_or_default(),
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
    // T12: a "Wash sale" column flags loss disposals disallowed by the
    // same-holding ±30-day rule; "safe to rebuy after" gives the first clear
    // date. Flagged losses are excluded from the liability (see the summary's
    // wash-sale-disallowed line) but still listed here for the 8949 trail.
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
        "Wash sale",
        "Safe to rebuy after",
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
            if d.wash_sale { "Yes" } else { "No" }.to_string(),
            d.wash_sale_safe_after.clone().unwrap_or_default(),
        ]);
    }
    let _ = wtr.write_record([""; 0]);

    // Section 2b — the excluded tax-advantaged activity, visible rather than
    // silently dropped. Only written when there is any.
    if disposals.iter().any(|d| d.tax_advantaged) {
        let _ =
            wtr.write_record(["Tax-advantaged account disposals (excluded from taxable gains)"]);
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
        // T5: net capital loss beyond the capped ordinary-income offset —
        // reported so it doesn't silently vanish (the app does not yet apply
        // it to other years).
        let _ = wtr.write_record([
            "Capital-loss carryforward (USD)",
            &money(est.capital_loss_carryforward),
        ]);
        // T12: losses disallowed by the wash-sale rule — already removed from
        // the ST/LT gains and the liability above, reported so the exclusion
        // is visible. Signed (<= 0).
        let _ = wtr.write_record([
            "Wash-sale disallowed loss (USD, excluded from liability)",
            &money(est.wash_sale_disallowed_loss),
        ]);
        let _ = wtr.write_record(["Ordinary income (USD)", &money(est.ordinary_income)]);
        // T6 decomposition — the three lines below re-sum to the ordinary
        // income total (disjoint buckets on category_detailed; the bracket
        // math runs over the total, never these parts).
        let _ = wtr.write_record([
            "  of which wages & other income (USD)",
            &money(est.wage_income),
        ]);
        let _ = wtr.write_record(["  of which dividends (USD)", &money(est.dividend_income)]);
        let _ = wtr.write_record(["  of which interest (USD)", &money(est.interest_income)]);
        let _ = wtr.write_record(["Ordinary income (MXN)", &money(est.ordinary_income_mxn)]);
        let _ = wtr.write_record(["Total taxable (USD)", &money(est.total_taxable)]);
        let _ = wtr.write_record([
            "Total taxable (MXN, basis for SAT tarifa)",
            &money(est.total_taxable_mxn),
        ]);
        let _ = wtr.write_record([
            "Estimated liability — US IRS (USD)",
            &money(est.estimated_liability_us),
        ]);
        let _ = wtr.write_record([
            "Estimated liability — MX SAT (MXN)",
            &money(est.estimated_liability_mx_mxn),
        ]);
        let _ = wtr.write_record([
            "Estimated liability — MX SAT (USD)",
            &money(est.estimated_liability_mx),
        ]);
        let _ = wtr.write_record([
            "USD/MXN rate used for year-level conversions",
            &est.usd_mxn_rate_used.round_dp(4).to_string(),
        ]);
        let basis = if est.gains_from_lots {
            "Precise lot disposals"
        } else {
            "No lot disposals on file"
        };
        let _ = wtr.write_record(["Capital-gains basis", basis]);
        // T4: which bracket-year tables were applied, and whether their
        // constants have passed human verification yet.
        let _ = wtr.write_record(["Bracket year used", &est.bracket_year_used.to_string()]);
        let _ = wtr.write_record([
            "Tax constants verified",
            if est.constants_verified {
                "yes"
            } else {
                "no - pending human verification"
            },
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
        format!("attachment; filename=\"tax_export_{year}.csv\"")
            .parse()
            .unwrap(),
    );

    (headers, csv_data).into_response()
}

async fn export_tax_pdf(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TaxQuery>,
) -> axum::response::Response {
    let year = match query.resolved_year() {
        Ok(y) => y,
        Err(e) => return e.into_response(),
    };
    let status = resolve_filing_status(&state, ctx.user_id, query.status).await;

    let estimation =
        match TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id).await {
            Ok(est) => est,
            Err(e) => {
                tracing::error!("Failed to calculate tax estimation (export): {}", e);
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    // Generic message to the client; the real error is logged
                    // via tracing::error! above (§1: never leak internals on a 500).
                    Json(serde_json::json!({ "error": "Internal server error" })),
                )
                    .into_response();
            }
        };

    use lopdf::content::{Content, Operation};
    use lopdf::{dictionary, Document, Object};

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
        ops.push(Operation::new(
            "Td",
            vec![(50 + indent).into(), (*y).into()],
        ));
        ops.push(Operation::new("Tj", vec![Object::string_literal(text)]));
        ops.push(Operation::new("ET", vec![]));
        *y -= if size >= 20 { 40 } else { 22 };
    };

    line(
        &mut ops,
        &mut y,
        20,
        0,
        format!("Patrimonio Tax Summary - {year}"),
    );
    line(&mut ops, &mut y, 12, 0, format!("Filing Status: {status}"));
    y -= 8; // small gap before the figures
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!(
            "Ordinary Income: ${}",
            estimation.ordinary_income.round_dp(2)
        ),
    );
    // T6: dividends/interest decomposition behind the ordinary-income figure,
    // indented as sub-detail like the ST/LT split below. Only shown when
    // there IS investment income — an all-wages year keeps the short layout.
    if estimation.dividend_income != rust_decimal::Decimal::ZERO
        || estimation.interest_income != rust_decimal::Decimal::ZERO
    {
        line(
            &mut ops,
            &mut y,
            11,
            20,
            format!(
                "Wages & other income: ${}",
                estimation.wage_income.round_dp(2)
            ),
        );
        line(
            &mut ops,
            &mut y,
            11,
            20,
            format!("Dividends: ${}", estimation.dividend_income.round_dp(2)),
        );
        line(
            &mut ops,
            &mut y,
            11,
            20,
            format!("Interest: ${}", estimation.interest_income.round_dp(2)),
        );
    }
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
        format!(
            "Total Taxable Amount: ${}",
            estimation.total_taxable.round_dp(2)
        ),
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
    // MX liability: the tarifa's native MXN output first, with the USD
    // equivalent (at the year-level rate) alongside so the line is unit-
    // unambiguous and reconciles with both the CSV and the on-screen card.
    line(
        &mut ops,
        &mut y,
        12,
        0,
        format!(
            "Estimated Liability (MX SAT): MXN {} (USD {})",
            estimation.estimated_liability_mx_mxn.round_dp(2),
            estimation.estimated_liability_mx.round_dp(2)
        ),
    );
    // T5: a leftover net capital loss is part of the picture — show it.
    if estimation.capital_loss_carryforward != rust_decimal::Decimal::ZERO {
        line(
            &mut ops,
            &mut y,
            11,
            20,
            format!(
                "Capital-loss carryforward: ${}",
                estimation.capital_loss_carryforward.round_dp(2)
            ),
        );
    }
    // T4: the bracket vintage actually used, flagged while the constant
    // tables are still pending human verification.
    y -= 8;
    line(
        &mut ops,
        &mut y,
        10,
        0,
        format!(
            "Bracket year used: {}{}",
            estimation.bracket_year_used,
            if estimation.constants_verified {
                ""
            } else {
                " - tax constants pending human verification; estimates only"
            }
        ),
    );

    let content = Content { operations: ops };

    let content_id = doc.add_object(lopdf::Stream::new(
        dictionary! {},
        content.encode().unwrap(),
    ));
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
        format!("attachment; filename=\"tax_summary_{year}.pdf\"")
            .parse()
            .unwrap(),
    );

    (headers, pdf_bytes).into_response()
}
