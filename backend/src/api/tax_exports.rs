//! Tax-filing export pack — one-click year-end documents.
//!
//! Four exports for a selected tax year, all built strictly on the tax
//! computations that already drive the Tax planning screen (no new tax math
//! lives here — see the rust-backend skill and the tax module docs):
//!
//!   * `GET /export/fbar`        — FBAR / FinCEN Form 114 worksheet (HTML,
//!     printable like the loan agreement): per foreign account — institution,
//!     account label, maximum annual balance in USD — from
//!     [`TaxService::fbar_status`] (the FBAR monitor's carry-forward peaks).
//!   * `GET /export/8949`        — Form-8949-shaped CSV of realized gains,
//!     Part I (short-term) / Part II (long-term), with proceeds / cost basis /
//!     gain columns, from [`TaxService::get_lot_disposals`].
//!   * `GET /export/schedule-b`  — Schedule-B-shaped CSV of interest income:
//!     personal-loan interest per borrower (cash basis, `loan_payments`) plus
//!     bank/CETES/bond interest per account (`INCOME_INTEREST_EARNED` rows —
//!     the same bucket the summary's `interest_income` is built from).
//!   * `GET /export/mx`          — MX annual summary CSV (realized gains,
//!     dividends, interest, simplified-tarifa ISR estimate) echoing
//!     [`TaxService::calculate_yearly_tax`] — the figures the MX card shows.
//!
//! Merged into `api::tax::router()` so the routes live under `/api/tax` and
//! inherit the same auth/CSRF middleware (and the tax integration-test router).

use axum::{
    extract::{Extension, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use chrono::Datelike;
use csv::WriterBuilder;
use rust_decimal::Decimal;
use serde::Deserialize;

use crate::api::session::{internal, ApiError, AuthContext};
use crate::api::tax::resolve_filing_status;
use crate::services::tax::{TaxService, AMOUNT_USD_SQL, USD_MXN_ROW_RATE_SQL};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/export/fbar", get(export_fbar_worksheet))
        .route("/export/8949", get(export_form_8949_csv))
        .route("/export/schedule-b", get(export_schedule_b_csv))
        .route("/export/mx", get(export_mx_summary_csv))
}

#[derive(Deserialize)]
struct ExportQuery {
    year: Option<i32>,
    /// Filing status override (MX summary only — the tarifa itself is
    /// status-independent but the shared estimation call takes one).
    status: Option<String>,
    /// `es` for Spanish, anything else (or absent) for English — the FBAR
    /// worksheet is bilingual like the loan printable.
    lang: Option<String>,
}

/// The requested export year, defaulting to the current one, rejected with
/// 400 when out of range.
///
/// Same panic as the sibling tax endpoints: these exports feed
/// `TaxService::*` which build their date bounds with
/// `NaiveDate::from_ymd_opt(year, 1, 1).unwrap()`, and chrono returns `None`
/// outside ±262143 — so `?year=300000` panicked mid-handler instead of
/// answering. Bounds are shared with `api::tax` so the two can't diverge.
fn year_or_current(q: &ExportQuery) -> Result<i32, ApiError> {
    let year = q
        .year
        .unwrap_or_else(|| chrono::Utc::now().naive_utc().year());
    if !(crate::api::tax::MIN_TAX_YEAR..=crate::api::tax::MAX_TAX_YEAR).contains(&year) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            &format!(
                "year must be between {} and {}",
                crate::api::tax::MIN_TAX_YEAR,
                crate::api::tax::MAX_TAX_YEAR
            ),
        ));
    }
    Ok(year)
}

/// Always-two-decimals money cell for the CSVs — `round_dp(2).to_string()`
/// leaves whole values as "0" while others show "0.00" (same fix as the
/// existing tax CSV export).
fn money(d: Decimal) -> String {
    format!("{d:.2}")
}

/// `12345.678` → `"12,345.68"` — thousands-grouped display money for the
/// HTML worksheet (the CSVs stay machine-plain via [`money`]).
fn money_grouped(d: Decimal) -> String {
    let plain = format!("{:.2}", d.abs());
    let (int_part, frac_part) = plain.split_once('.').unwrap_or((plain.as_str(), "00"));
    let mut grouped = String::new();
    for (i, ch) in int_part.chars().enumerate() {
        if i > 0 && (int_part.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    let sign = if d.is_sign_negative() && !d.is_zero() {
        "-"
    } else {
        ""
    };
    format!("{sign}{grouped}.{frac_part}")
}

fn esc_html(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn csv_attachment(filename: &str, body: Vec<u8>) -> Response {
    (
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{filename}\""),
            ),
        ],
        body,
    )
        .into_response()
}

// =====================================================================
// (a) FBAR / FinCEN Form 114 worksheet — printable HTML
// =====================================================================

/// Per-foreign-account worksheet for FinCEN Form 114: institution, account
/// label, country/currency, and the maximum annual balance in USD — exactly
/// the per-account `ytd_max_usd` the FBAR monitor already computes (sum of
/// per-account maxes = the aggregate that drives `exceeded`). Rendered as a
/// self-contained printable HTML page, same pattern as the loan agreement
/// printable (user prints to PDF; zero-margin `@page` keeps the PDF clean).
async fn export_fbar_worksheet(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<ExportQuery>,
) -> Result<Response, ApiError> {
    let year = year_or_current(&q)?;
    let es = q.lang.as_deref() == Some("es");
    let t = |en: &'static str, es_s: &'static str| if es { es_s } else { en };

    let fbar = TaxService::fbar_status(&state.db, year, ctx.user_id)
        .await
        .map_err(internal)?;

    let mut rows_html = String::new();
    for a in &fbar.foreign_accounts {
        // Account number column is deliberately BLANK: the app stores masked
        // labels at best, and FinCEN wants the real number — the user fills
        // it in by hand on the printed worksheet.
        rows_html.push_str(&format!(
            "<tr><td>{inst}</td><td>{name}</td><td class=\"st\">{country}</td>\
             <td class=\"st\">{currency}</td><td class=\"fill\"></td>\
             <td class=\"num\">${max}</td></tr>",
            inst = esc_html(&a.institution),
            name = esc_html(&a.name),
            country = esc_html(a.country.as_deref().unwrap_or("—")),
            currency = esc_html(&a.currency),
            max = money_grouped(a.ytd_max_usd),
        ));
    }
    if fbar.foreign_accounts.is_empty() {
        rows_html.push_str(&format!(
            "<tr><td colspan=\"6\" class=\"empty\">{}</td></tr>",
            t(
                "No foreign accounts with balance history in this year.",
                "Sin cuentas extranjeras con historial de saldos en este año."
            )
        ));
    }

    let exceeded_val = if fbar.exceeded {
        t("Yes — filing indicated", "Sí — declaración indicada")
    } else {
        t("No — under the threshold", "No — debajo del umbral")
    };
    let peak_line = match &fbar.peak_date {
        Some(d) => format!(
            "{} {}",
            t("Peak aggregate date:", "Fecha del máximo agregado:"),
            esc_html(d)
        ),
        None => t("No snapshots in this year.", "Sin registros en este año.").to_string(),
    };
    // While the constant tables are pending human verification, say so on the
    // document itself (same gating the on-screen FBAR monitor applies).
    let unverified_note = if fbar.constants_verified {
        String::new()
    } else {
        format!(
            "<p class=\"note\">{}</p>",
            t(
                "Threshold constant pending human verification — estimates only.",
                "Umbral pendiente de verificación humana — solo estimaciones."
            )
        )
    };
    let (en_cls, es_cls) = if es { ("", "on") } else { ("on", "") };

    let html = format!(
        r#"<!DOCTYPE html><html lang="{doc_lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — {year}</title>
<style>
  :root {{ --ink:#1f2933; --muted:#6b7280; --line:#e5e7eb; --accent:#0f766e; --soft:#f0fdfa; --bg:#ffffff; }}
  * {{ box-sizing: border-box; }}
  body {{ font-family: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 820px; margin: 0 auto; color: var(--ink); line-height: 1.55; padding: 24px 20px 64px; background: var(--bg); }}
  .topbar {{ display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; margin-bottom: 20px; }}
  .brand {{ font-size:12px; font-weight:700; letter-spacing:.14em; text-transform:uppercase; color:var(--accent); }}
  .tools {{ display:flex; align-items:center; gap:10px; }}
  .lang a {{ text-decoration:none; color:var(--muted); font-size:12px; font-weight:600; padding:3px 7px; border-radius:6px; }}
  .lang a.on {{ background:var(--soft); color:var(--accent); }}
  button.print {{ font: inherit; font-size:12px; font-weight:600; padding:7px 12px; border:1px solid var(--accent); background:var(--accent); color:#fff; border-radius:8px; cursor:pointer; }}
  h1 {{ font-size: 24px; margin: 0 0 4px; letter-spacing:-0.01em; }}
  .subtitle {{ color:var(--muted); font-size:13px; margin:0 0 24px; }}
  h2 {{ font-size: 13px; text-transform:uppercase; letter-spacing:.08em; color:var(--accent); margin: 30px 0 10px; }}
  .cards {{ display:grid; grid-template-columns: repeat(3, 1fr); gap:12px; margin-top:8px; }}
  .card {{ border:1px solid var(--line); border-radius:12px; padding:14px 16px; background:var(--bg); }}
  .card .k {{ font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.05em; }}
  .card .val {{ font-size:20px; font-weight:800; margin-top:4px; font-variant-numeric: tabular-nums; }}
  .card .sub {{ font-size:11px; color:var(--muted); margin-top:6px; }}
  .card.accent {{ background:var(--soft); border-color:#99f6e4; }}
  .card.accent .val {{ color:var(--accent); }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }}
  thead th {{ background:var(--soft); color:var(--accent); text-align:left; padding:8px 10px; border-bottom:2px solid #99f6e4; font-size:11px; text-transform:uppercase; letter-spacing:.05em; }}
  tbody td {{ padding:7px 10px; border-bottom:1px solid var(--line); }}
  tbody tr:nth-child(even) {{ background:#fafafa; }}
  td.num, th.num {{ text-align:right; font-variant-numeric: tabular-nums; }}
  td.st, th.st {{ text-align:center; white-space:nowrap; }}
  td.fill {{ min-width:120px; border-bottom:1px dashed var(--muted); }}
  td.empty {{ color:var(--muted); text-align:center; padding:18px 10px; }}
  .note {{ margin-top: 28px; font-size: 11px; color: var(--muted); border-top:1px solid var(--line); padding-top:12px; }}
  @media (max-width: 520px) {{ .cards {{ grid-template-columns: 1fr; }} }}
  /* Zero @page margins suppress the browser's print header/footer; the
     document supplies its own margins via body padding (loan-printable
     convention), so the saved PDF is clean. */
  @page {{ margin: 0; }}
  @media print {{ body {{ padding: 16mm 18mm 18mm; }} .tools {{ display:none; }} .card, thead th {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }} }}
</style></head><body>
<div class="topbar">
  <span class="brand">Patrimonio</span>
  <div class="tools">
    <span class="lang"><a href="?year={year}&amp;lang=en" class="{en_cls}">EN</a><a href="?year={year}&amp;lang=es" class="{es_cls}">ES</a></span>
    <button class="print" onclick="window.print()">{print}</button>
  </div>
</div>
<h1>{title} — {year}</h1>
<p class="subtitle">{subtitle}</p>

<h2>{summary_hdr}</h2>
<div class="cards">
  <div class="card"><div class="k">{agg_lbl}</div><div class="val">${peak_agg}</div><div class="sub">{agg_sub}</div></div>
  <div class="card"><div class="k">{thr_lbl}</div><div class="val">${threshold}</div></div>
  <div class="card accent"><div class="k">{exceeded_lbl}</div><div class="val">{exceeded_val}</div><div class="sub">{peak_line}</div></div>
</div>

<h2>{accounts_hdr}</h2>
<table>
  <thead><tr>
    <th>{inst_col}</th><th>{acct_col}</th><th class="st">{country_col}</th>
    <th class="st">{ccy_col}</th><th>{num_col}</th><th class="num">{max_col}</th>
  </tr></thead>
  <tbody>{rows_html}</tbody>
</table>
{unverified_note}
<p class="note">{disclaimer}</p>
</body></html>"#,
        doc_lang = if es { "es" } else { "en" },
        title = t("FBAR / FinCEN Form 114 worksheet", "Hoja de trabajo FBAR / FinCEN Formulario 114"),
        subtitle = t(
            "Maximum annual balance per foreign account, converted to USD — a preparation aid for the FinCEN Form 114 filing.",
            "Saldo máximo anual por cuenta extranjera, convertido a USD — apoyo para preparar el Formulario 114 de FinCEN."
        ),
        print = t("Print / Save as PDF", "Imprimir / Guardar como PDF"),
        summary_hdr = t("Year summary", "Resumen del año"),
        agg_lbl = t("Aggregate of account maxima", "Agregado de máximos por cuenta"),
        agg_sub = t(
            "Sum of each account's own annual maximum (never under-reports).",
            "Suma del máximo anual de cada cuenta (nunca subreporta)."
        ),
        peak_agg = money_grouped(fbar.peak_aggregate_usd),
        thr_lbl = t("Reporting threshold", "Umbral de declaración"),
        threshold = money_grouped(fbar.threshold_usd),
        exceeded_lbl = t("Threshold exceeded?", "¿Umbral superado?"),
        accounts_hdr = t("Foreign accounts", "Cuentas extranjeras"),
        inst_col = t("Institution", "Institución"),
        acct_col = t("Account", "Cuenta"),
        country_col = t("Country", "País"),
        ccy_col = t("Currency", "Moneda"),
        num_col = t("Account number (fill in)", "Número de cuenta (completar)"),
        max_col = t("Max annual balance (USD)", "Saldo máximo anual (USD)"),
        disclaimer = t(
            "Generated by Patrimonio from stored balance snapshots as a preparation aid — informational only, not tax advice, and not a filing decision. FBAR valuation rules (e.g. the Treasury year-end exchange rate) may differ from the app's stored-rate conversions; verify every figure before filing.",
            "Generado por Patrimonio a partir de los saldos registrados como apoyo de preparación — solo informativo, no es asesoría fiscal ni una decisión de declaración. Las reglas de valuación del FBAR (p. ej. el tipo de cambio de fin de año del Tesoro) pueden diferir de las conversiones de la app; verifica cada cifra antes de declarar."
        ),
    );

    Ok((
        [(header::CONTENT_TYPE, "text/html; charset=utf-8".to_string())],
        html,
    )
        .into_response())
}

// =====================================================================
// (b) Form 8949-shaped CSV — realized gains, Part I / Part II
// =====================================================================

/// Realized capital gains shaped like Form 8949: Part I (short-term, which
/// also carries unknown-acquisition rows — the same conservative bucketing
/// the liability applies, labeled honestly as "Unknown") and Part II
/// (long-term), each with description / dates / proceeds / cost basis /
/// gain and a per-part total. Tax-advantaged disposals are NOT taxable
/// events and are excluded (a trailing note reports how many were).
async fn export_form_8949_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<ExportQuery>,
) -> Result<Response, ApiError> {
    let year = year_or_current(&q)?;
    let disposals = TaxService::get_lot_disposals(&state.db, year, ctx.user_id)
        .await
        .map_err(internal)?;

    // Section headers vs data rows vary in width → flexible writer, same as
    // the existing tax CSV.
    let mut wtr = WriterBuilder::new().flexible(true).from_writer(vec![]);
    let _ = wtr.write_record(["Patrimonio Form 8949 worksheet", &year.to_string()]);
    let _ = wtr.write_record([
        "Realized gains from lot disposals; verify against broker 1099-B before filing.",
    ]);
    let _ = wtr.write_record([""; 0]);

    let taxable: Vec<_> = disposals.iter().filter(|d| !d.tax_advantaged).collect();
    let excluded_count = disposals.len() - taxable.len();

    // Part I gets short-term AND unknown-term rows: unknown acquisition is
    // counted short-term in the liability (the higher-rate, conservative
    // bucket), and the export mirrors that while keeping the honest label.
    let part = |wtr: &mut csv::Writer<Vec<u8>>,
                title: &str,
                rows: &[&crate::services::tax::TaxDisposal]| {
        let _ = wtr.write_record([title]);
        let _ = wtr.write_record([
            "Description of property",
            "Date acquired",
            "Date sold",
            "Proceeds (USD)",
            "Cost basis (USD)",
            "Gain/loss (USD)",
            "Term",
            "Wash sale",
        ]);
        let mut proceeds = Decimal::ZERO;
        let mut cost = Decimal::ZERO;
        let mut gain = Decimal::ZERO;
        for d in rows {
            proceeds += d.proceeds_usd;
            cost += d.cost_usd;
            gain += d.gain_usd;
            let term = match d.long_term {
                Some(true) => "Long-term",
                Some(false) => "Short-term",
                None => "Unknown",
            };
            let _ = wtr.write_record([
                // Form 8949 column (a) style: "100 sh. XYZ Co."
                format!("{} sh. {} ({})", d.qty_sold.normalize(), d.symbol, d.name),
                d.acquired_date.clone().unwrap_or_default(),
                d.sell_date.clone(),
                money(d.proceeds_usd),
                money(d.cost_usd),
                money(d.gain_usd),
                term.to_string(),
                if d.wash_sale { "Yes" } else { "No" }.to_string(),
            ]);
        }
        let _ = wtr.write_record([
            "Total".to_string(),
            String::new(),
            String::new(),
            money(proceeds),
            money(cost),
            money(gain),
        ]);
        let _ = wtr.write_record([""; 0]);
    };

    let short_rows: Vec<_> = taxable
        .iter()
        .filter(|d| d.long_term != Some(true))
        .copied()
        .collect();
    let long_rows: Vec<_> = taxable
        .iter()
        .filter(|d| d.long_term == Some(true))
        .copied()
        .collect();
    part(
        &mut wtr,
        "Part I - Short-term (includes unknown holding periods, bucketed short-term)",
        &short_rows,
    );
    part(&mut wtr, "Part II - Long-term", &long_rows);

    if excluded_count > 0 {
        let _ = wtr.write_record([
            "Note: tax-advantaged account disposals excluded (not taxable events)",
            &excluded_count.to_string(),
        ]);
    }
    let _ = wtr.write_record([
        "Note: wash-sale-flagged losses are disallowed for the year; see the full tax CSV export for the summary lines.",
    ]);

    let body = wtr.into_inner().unwrap_or_default();
    Ok(csv_attachment(
        &format!("patrimonio_form8949_{year}.csv"),
        body,
    ))
}

// =====================================================================
// (c) Schedule B-shaped CSV — interest income by payer
// =====================================================================

/// Interest income by payer, Schedule-B style: one row per personal-loan
/// borrower (cash-basis interest received in the year — the lending module's
/// stored splits) plus one row per account that received bank/CETES/bond
/// interest (`INCOME_INTEREST_EARNED` transactions — the exact bucket the
/// tax summary's `interest_income` decomposition uses, so those rows sum to
/// that figure). Every row is FX-converted to USD per row/date; native
/// amounts are also reported per currency so nothing is summed across an FX
/// boundary unlabeled.
async fn export_schedule_b_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<ExportQuery>,
) -> Result<Response, ApiError> {
    let year = year_or_current(&q)?;
    let start = format!("{year}-01-01");
    let end = format!("{year}-12-31");

    // Personal-loan interest per borrower. The inner subquery renames the
    // loan-payment columns to the `t.date` / `t.currency` / `t.amount` shape
    // the canonical FX fragments expect, so the SAME per-row conversion rule
    // the tax summary uses (USD_MXN_ROW_RATE_SQL + AMOUNT_USD_SQL) applies
    // here — no second FX rule to drift out of sync.
    let loan_sql = format!(
        r#"
        SELECT t.payer, t.currency,
               COALESCE(SUM(t.amount), 0) AS interest_native,
               COALESCE(SUM({AMOUNT_USD_SQL}), 0) AS interest_usd
        FROM (
            SELECT l.borrower_name AS payer, l.currency AS currency,
                   p.interest_portion AS amount, p.paid_date AS date
            FROM loan_payments p
            JOIN loans l ON l.id = p.loan_id AND l.user_id = p.user_id
            WHERE p.user_id = $1
              AND p.interest_portion IS NOT NULL
              AND p.interest_portion <> 0
              AND p.paid_date IS NOT NULL
              AND EXTRACT(YEAR FROM p.paid_date)::int = $2
        ) t
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        GROUP BY t.payer, t.currency
        ORDER BY interest_usd DESC
        "#
    );
    let loan_rows = sqlx::query(&loan_sql)
        .bind(ctx.user_id)
        .bind(year)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // Account interest (bank savings, CETES/BONDDIA, bond coupons): the
    // INCOME_INTEREST_EARNED rows, grouped per institution + account so the
    // payer column reads like a Schedule B line. Same alias shape (`t`) so
    // the shared FX fragments bind directly.
    let acct_sql = format!(
        r#"
        SELECT i.name AS institution,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               t.currency,
               COALESCE(SUM(t.amount), 0) AS interest_native,
               COALESCE(SUM({AMOUNT_USD_SQL}), 0) AS interest_usd
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        JOIN institutions i ON i.id = a.institution_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.user_id = $1
          AND t.date >= $2::date AND t.date <= $3::date
          AND t.amount > 0
          AND UPPER(t.category_detailed) = 'INCOME_INTEREST_EARNED'
        GROUP BY i.name, COALESCE(NULLIF(a.nickname, ''), a.name), t.currency
        ORDER BY interest_usd DESC
        "#
    );
    let acct_rows = sqlx::query(&acct_sql)
        .bind(ctx.user_id)
        .bind(&start)
        .bind(&end)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    use sqlx::Row;
    let mut wtr = WriterBuilder::new().flexible(true).from_writer(vec![]);
    let _ = wtr.write_record([
        "Patrimonio Schedule B worksheet - interest income",
        &year.to_string(),
    ]);
    let _ = wtr.write_record([""; 0]);
    let _ = wtr.write_record(["Part I - Interest"]);
    let _ = wtr.write_record([
        "Payer",
        "Source",
        "Currency",
        "Interest (native)",
        "Interest (USD)",
    ]);

    let mut total_usd = Decimal::ZERO;
    for r in &loan_rows {
        let payer: String = r.try_get("payer").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let native: Decimal = r.try_get("interest_native").unwrap_or_default();
        let usd: Decimal = r.try_get("interest_usd").unwrap_or_default();
        total_usd += usd;
        let _ = wtr.write_record([
            payer,
            "Personal loan (cash basis)".to_string(),
            currency,
            money(native),
            money(usd),
        ]);
    }
    for r in &acct_rows {
        let institution: String = r.try_get("institution").unwrap_or_default();
        let account: String = r.try_get("account_name").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let native: Decimal = r.try_get("interest_native").unwrap_or_default();
        let usd: Decimal = r.try_get("interest_usd").unwrap_or_default();
        total_usd += usd;
        let _ = wtr.write_record([
            institution,
            format!("Account interest - {account}"),
            currency,
            money(native),
            money(usd),
        ]);
    }
    let _ = wtr.write_record([""; 0]);
    let _ = wtr.write_record(["Total interest (USD)", &money(total_usd)]);
    let _ = wtr.write_record([""; 0]);
    let _ = wtr.write_record([
        "Note: account rows reconcile with the tax summary's interest-income figure; personal-loan interest is tracked in the lending module (cash basis, by payment date) and is additional to it.",
    ]);

    let body = wtr.into_inner().unwrap_or_default();
    Ok(csv_attachment(
        &format!("patrimonio_schedule_b_{year}.csv"),
        body,
    ))
}

// =====================================================================
// (d) MX annual summary CSV — the simplified-tarifa scenario
// =====================================================================

/// MX (SAT) annual summary: realized gains, dividends, interest, and the
/// simplified tarifa-over-everything ISR estimate — the exact figures the MX
/// card shows, straight from [`TaxService::calculate_yearly_tax`]. Where a
/// component only exists in USD (dividends/interest, capital gains), its MXN
/// companion is derived at the estimation's own year-level rate
/// (`usd_mxn_rate_used`), which is reported so every conversion is auditable.
async fn export_mx_summary_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<ExportQuery>,
) -> Result<Response, ApiError> {
    let year = year_or_current(&q)?;
    let status = resolve_filing_status(&state, ctx.user_id, q.status.clone()).await;
    let est = TaxService::calculate_yearly_tax(&state.db, year, &status, ctx.user_id)
        .await
        .map_err(internal)?;

    let rate = est.usd_mxn_rate_used;
    let to_mxn = |usd: Decimal| usd * rate;

    let mut wtr = WriterBuilder::new().flexible(true).from_writer(vec![]);
    let _ = wtr.write_record(["Patrimonio MX annual summary (SAT)", &year.to_string()]);
    let _ = wtr.write_record([
        "Simplified scenario: the ISR tarifa is applied over ordinary income plus realized gains (no preferential buckets) - same figures as the MX card.",
    ]);
    let _ = wtr.write_record([""; 0]);

    let _ = wtr.write_record(["Line", "MXN", "USD"]);
    // Ordinary income's MXN figure is the PER-ROW converted sum the tarifa
    // actually consumes; the component lines below only exist in USD, so
    // their MXN companions use the year-level rate (labeled at the bottom).
    let _ = wtr.write_record([
        "Ordinary income".to_string(),
        money(est.ordinary_income_mxn),
        money(est.ordinary_income),
    ]);
    let _ = wtr.write_record([
        "  of which dividends (MXN at year rate)".to_string(),
        money(to_mxn(est.dividend_income)),
        money(est.dividend_income),
    ]);
    let _ = wtr.write_record([
        "  of which interest (MXN at year rate)".to_string(),
        money(to_mxn(est.interest_income)),
        money(est.interest_income),
    ]);
    let _ = wtr.write_record([
        "Realized capital gains (MXN at year rate)".to_string(),
        money(to_mxn(est.capital_gains)),
        money(est.capital_gains),
    ]);
    let _ = wtr.write_record([
        "Total taxable (tarifa base)".to_string(),
        money(est.total_taxable_mxn),
        money(est.total_taxable),
    ]);
    let _ = wtr.write_record([
        "Estimated ISR liability".to_string(),
        money(est.estimated_liability_mx_mxn),
        money(est.estimated_liability_mx),
    ]);
    let _ = wtr.write_record([
        "ISR withheld at source".to_string(),
        money(est.isr_withheld_mxn),
        money(est.isr_withheld_usd),
    ]);
    // Same presentation the MX card uses: estimated minus withheld, floored
    // at zero (withholding is informational; never auto-credited beyond the
    // display line).
    let remaining_mxn = (est.estimated_liability_mx_mxn - est.isr_withheld_mxn).max(Decimal::ZERO);
    let _ = wtr.write_record([
        "Estimated minus withheld (display only)".to_string(),
        money(remaining_mxn),
        String::new(),
    ]);
    let _ = wtr.write_record([""; 0]);
    let _ = wtr.write_record([
        "USD/MXN rate used for year-level conversions",
        &rate.round_dp(4).to_string(),
    ]);
    let _ = wtr.write_record(["Bracket year used", &est.bracket_year_used.to_string()]);
    let _ = wtr.write_record([
        "Tax constants verified",
        if est.constants_verified {
            "yes"
        } else {
            "no - pending human verification"
        },
    ]);

    let body = wtr.into_inner().unwrap_or_default();
    Ok(csv_attachment(
        &format!("patrimonio_mx_summary_{year}.csv"),
        body,
    ))
}
