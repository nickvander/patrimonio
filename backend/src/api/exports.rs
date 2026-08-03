//! Household continuity dossier — a printable "open in emergency" packet.
//!
//! `GET /export/continuity-dossier?lang=en|es` renders a self-contained,
//! bilingual HTML inventory of everything the app knows about the user's
//! financial life: institutions + accounts with their last known balances,
//! manual-asset valuations, a holdings summary, the personal lending book,
//! FBAR/foreign-reportability flags, and an owner-written free-text
//! instructions section (app_settings key `continuity_notes`). The user
//! prints it to PDF and keeps it in a folder or safe, so the household
//! member / executor who has to take over has a current inventory even if
//! the self-hosted server dies with its admin.
//!
//! Follows the tax_exports.rs FBAR-worksheet recipe exactly (same lang
//! toggle, same print CSS, same `t(en, es)` closure); the loan agreement in
//! loans.rs is the second precedent. Mounted under `/api/exports` on the
//! protected business router, so auth + CSRF + `require_owner` (GETs pass)
//! apply like every other business route.
//!
//! HARD RULE — no secrets, ever: this export never touches a `*_enc`
//! column, session/passkey material, or webhook/deployment config. Names
//! and balances only; the cover page says so explicitly. An integration
//! test (`tests/continuity_dossier_endpoints.rs`) asserts the rendered HTML
//! contains no encrypted-column material.

use axum::{
    extract::{Extension, Query, State},
    http::header,
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::Deserialize;
use sqlx::Row;

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/continuity-dossier", get(continuity_dossier))
}

#[derive(Deserialize)]
struct DossierQuery {
    /// `es` for Spanish, anything else (or absent) for English — same
    /// convention as the FBAR worksheet and the loan agreement.
    lang: Option<String>,
}

/// `12345.678` → `"12,345.68"` — thousands-grouped display money.
/// Duplicated from tax_exports.rs (private there); if a third printable
/// needs it, extract a shared helper module instead of a fourth copy.
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

/// The whole dossier in one handler: several small scoped queries, then one
/// big `format!` into the shared printable-HTML skeleton. Every query is
/// `WHERE user_id = $1` (row-level isolation invariant).
async fn continuity_dossier(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<DossierQuery>,
) -> Result<Response, ApiError> {
    let es = q.lang.as_deref() == Some("es");
    let t = |en: &'static str, es_s: &'static str| if es { es_s } else { en };

    // ------------------------------------------------------------------
    // Cover-page staleness: the newest stored snapshot date and the newest
    // institution sync. Computed, never hardcoded — the printed artifact
    // must be honest about how old its numbers are once it's off-server.
    // ------------------------------------------------------------------
    let staleness = sqlx::query(
        r#"
        SELECT
            (SELECT MAX(as_of_date) FROM balance_snapshots WHERE user_id = $1) AS newest_snapshot,
            (SELECT MAX(last_synced_at) FROM institutions WHERE user_id = $1) AS newest_sync
        "#,
    )
    .bind(ctx.user_id)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;
    let newest_snapshot: Option<NaiveDate> = staleness.try_get("newest_snapshot").ok().flatten();
    let newest_sync: Option<DateTime<Utc>> = staleness.try_get("newest_sync").ok().flatten();
    // "Data as of" = the newer of (latest snapshot date, latest sync date).
    let data_as_of: Option<NaiveDate> = match (newest_snapshot, newest_sync.map(|s| s.date_naive()))
    {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    };
    let data_as_of_str = data_as_of
        .map(|d| d.to_string())
        .unwrap_or_else(|| t("no data yet", "aún sin datos").to_string());
    let generated_str = Utc::now().format("%Y-%m-%d %H:%M UTC").to_string();

    // ------------------------------------------------------------------
    // Owner-written instructions (app_settings key `continuity_notes` —
    // same per-user JSONB store `projection_assumptions` uses; the generic
    // GET/PUT /api/settings/{key} handlers do the writing).
    // ------------------------------------------------------------------
    let notes_value: Option<serde_json::Value> = sqlx::query_scalar(
        "SELECT value FROM app_settings WHERE key = 'continuity_notes' AND user_id = $1",
    )
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;
    let notes_text = notes_value
        .as_ref()
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    let notes_html = if notes_text.is_empty() {
        format!(
            "<p class=\"empty-note\">{}</p>",
            t(
                "No instructions written yet — add them in Settings → Continuity dossier.",
                "Aún no hay instrucciones — agrégalas en Ajustes → Expediente de continuidad."
            )
        )
    } else {
        // pre-wrap keeps the owner's line breaks; esc_html neutralizes markup.
        format!("<div class=\"notes\">{}</div>", esc_html(&notes_text))
    };

    // ------------------------------------------------------------------
    // Institutions & accounts with their last known balance. One LATERAL
    // per account picks that account's newest snapshot (ORDER BY
    // as_of_date DESC, id DESC — the same last-row-wins rule as the
    // carry-forward pattern; NEVER a per-date GROUP BY, which drops
    // infrequently-synced accounts). Accounts with no snapshot fall back
    // to accounts.current_balance / updated_at.
    //
    // The `is_foreign` flag mirrors TaxService::fbar_status's
    // classification (services/tax.rs): a positively non-US country is
    // foreign; the MXN heuristic applies only when the country is unknown.
    // `has_csv` distinguishes statement-import accounts from purely manual
    // ones (imported rows are stamped source = 'csv' by api/imports.rs).
    // ------------------------------------------------------------------
    let account_rows = sqlx::query(
        r#"
        SELECT i.name AS institution,
               i.country AS country,
               i.integration_type AS integration_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               a.account_type AS account_type,
               a.currency AS currency,
               COALESCE(s.balance, a.current_balance) AS last_balance,
               s.balance_usd AS balance_usd,
               COALESCE(s.as_of_date, a.updated_at::date) AS as_of_date,
               (UPPER(COALESCE(i.country, '')) NOT IN ('US', '')
                OR (COALESCE(i.country, '') = ''
                    AND UPPER(COALESCE(a.currency, '')) = 'MXN')) AS is_foreign,
               EXISTS (SELECT 1 FROM transactions tx
                       WHERE tx.account_id = a.id AND tx.user_id = $1
                         AND tx.source = 'csv') AS has_csv
        FROM accounts a
        JOIN institutions i ON i.id = a.institution_id
        LEFT JOIN LATERAL (
            SELECT b.balance, b.balance_usd, b.as_of_date
            FROM balance_snapshots b
            WHERE b.account_id = a.id AND b.user_id = $1
            ORDER BY b.as_of_date DESC, b.id DESC
            LIMIT 1
        ) s ON TRUE
        WHERE a.user_id = $1 AND a.archived_at IS NULL
        ORDER BY i.name, COALESCE(NULLIF(a.nickname, ''), a.name)
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let mut accounts_html = String::new();
    let mut foreign_count = 0usize;
    for r in &account_rows {
        let institution: String = r.try_get("institution").unwrap_or_default();
        let country: String = r.try_get("country").unwrap_or_default();
        let integration: String = r.try_get("integration_type").unwrap_or_default();
        let name: String = r.try_get("account_name").unwrap_or_default();
        let acct_type: String = r.try_get("account_type").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let balance: Option<Decimal> = r.try_get("last_balance").ok().flatten();
        let balance_usd: Option<Decimal> = r.try_get("balance_usd").ok().flatten();
        let as_of: Option<NaiveDate> = r.try_get("as_of_date").ok().flatten();
        let is_foreign: bool = r.try_get("is_foreign").unwrap_or(false);
        let has_csv: bool = r.try_get("has_csv").unwrap_or(false);
        if is_foreign {
            foreign_count += 1;
        }

        let integration_label = match integration.as_str() {
            "plaid" => "Plaid".to_string(),
            "manual" if has_csv => t("Statement import", "Importación de estados").to_string(),
            "manual" => t("Manual", "Manual").to_string(),
            "coinbase" | "coinbase_oauth" => "Coinbase".to_string(),
            "bitso" => "Bitso".to_string(),
            other => esc_html(other),
        };
        let balance_cell = balance
            .map(money_grouped)
            .unwrap_or_else(|| "—".to_string());
        let usd_cell = balance_usd
            .map(|b| format!("${}", money_grouped(b)))
            .unwrap_or_else(|| "—".to_string());
        let as_of_cell = as_of
            .map(|d| d.to_string())
            .unwrap_or_else(|| "—".to_string());
        let fbar_cell = if is_foreign {
            t("Yes", "Sí")
        } else {
            t("No", "No")
        };
        accounts_html.push_str(&format!(
            "<tr><td>{inst}</td><td>{name}</td><td class=\"st\">{typ}</td>\
             <td class=\"st\">{country}</td><td class=\"st\">{ccy}</td>\
             <td class=\"st\">{integ}</td><td class=\"num\">{bal}</td>\
             <td class=\"num\">{usd}</td><td class=\"st\">{asof}</td>\
             <td class=\"st\">{fbar}</td></tr>",
            inst = esc_html(&institution),
            name = esc_html(&name),
            typ = esc_html(&acct_type),
            country = esc_html(if country.is_empty() { "—" } else { &country }),
            ccy = esc_html(&currency),
            integ = integration_label,
            bal = balance_cell,
            usd = usd_cell,
            asof = as_of_cell,
            fbar = fbar_cell,
        ));
    }
    if account_rows.is_empty() {
        accounts_html.push_str(&format!(
            "<tr><td colspan=\"10\" class=\"empty\">{}</td></tr>",
            t(
                "No accounts tracked yet.",
                "Aún no hay cuentas registradas."
            )
        ));
    }

    // ------------------------------------------------------------------
    // Manual-asset valuations: the newest snapshot per account that
    // carries a valuation note (notes live on the snapshot row, one per
    // revaluation — migration 2026052601).
    // ------------------------------------------------------------------
    let valuation_rows = sqlx::query(
        r#"
        SELECT i.name AS institution,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               v.balance AS balance, v.currency AS currency,
               v.as_of_date AS as_of_date, v.valuation_notes AS notes
        FROM accounts a
        JOIN institutions i ON i.id = a.institution_id
        JOIN LATERAL (
            SELECT b.balance, b.currency, b.as_of_date, b.valuation_notes
            FROM balance_snapshots b
            WHERE b.account_id = a.id AND b.user_id = $1
              AND NULLIF(b.valuation_notes, '') IS NOT NULL
            ORDER BY b.as_of_date DESC, b.id DESC
            LIMIT 1
        ) v ON TRUE
        WHERE a.user_id = $1 AND a.archived_at IS NULL
        ORDER BY i.name, COALESCE(NULLIF(a.nickname, ''), a.name)
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let mut valuations_html = String::new();
    for r in &valuation_rows {
        let institution: String = r.try_get("institution").unwrap_or_default();
        let name: String = r.try_get("account_name").unwrap_or_default();
        let balance: Decimal = r.try_get("balance").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let as_of: Option<NaiveDate> = r.try_get("as_of_date").ok().flatten();
        let notes: String = r.try_get("notes").unwrap_or_default();
        valuations_html.push_str(&format!(
            "<tr><td>{inst}</td><td>{name}</td><td class=\"num\">{bal} {ccy}</td>\
             <td class=\"st\">{asof}</td><td>{notes}</td></tr>",
            inst = esc_html(&institution),
            name = esc_html(&name),
            bal = money_grouped(balance),
            ccy = esc_html(&currency),
            asof = as_of.map(|d| d.to_string()).unwrap_or_default(),
            notes = esc_html(&notes),
        ));
    }
    let valuations_section = if valuations_html.is_empty() {
        String::new() // most users have no noted revaluations — omit the section
    } else {
        format!(
            "<h2>{hdr}</h2><table><thead><tr><th>{inst}</th><th>{acct}</th>\
             <th class=\"num\">{val}</th><th class=\"st\">{date}</th><th>{note}</th></tr></thead>\
             <tbody>{rows}</tbody></table>",
            hdr = t("Manual asset valuations", "Valuaciones de activos manuales"),
            inst = t("Institution", "Institución"),
            acct = t("Asset", "Activo"),
            val = t("Latest valuation", "Última valuación"),
            date = t("Date", "Fecha"),
            note = t("Note", "Nota"),
            rows = valuations_html,
        )
    };

    // ------------------------------------------------------------------
    // Holdings summary per brokerage account. Native values only — one
    // row per holding, labeled with its own currency, so nothing is
    // summed across an FX boundary.
    // ------------------------------------------------------------------
    let holding_rows = sqlx::query(
        r#"
        SELECT i.name AS institution,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               h.symbol AS symbol, h.name AS holding_name,
               h.quantity AS quantity, h.value AS value, h.currency AS currency
        FROM holdings h
        JOIN accounts a ON a.id = h.account_id
        JOIN institutions i ON i.id = a.institution_id
        WHERE h.user_id = $1 AND h.deleted_at IS NULL AND a.archived_at IS NULL
        ORDER BY i.name, COALESCE(NULLIF(a.nickname, ''), a.name),
                 h.value DESC NULLS LAST, h.symbol
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let mut holdings_html = String::new();
    for r in &holding_rows {
        let institution: String = r.try_get("institution").unwrap_or_default();
        let account: String = r.try_get("account_name").unwrap_or_default();
        let symbol: String = r.try_get("symbol").unwrap_or_default();
        let holding_name: String = r.try_get("holding_name").unwrap_or_default();
        let quantity: Option<Decimal> = r.try_get("quantity").ok().flatten();
        let value: Option<Decimal> = r.try_get("value").ok().flatten();
        let currency: String = r.try_get("currency").unwrap_or_default();
        holdings_html.push_str(&format!(
            "<tr><td>{inst}</td><td>{acct}</td><td class=\"st\">{sym}</td><td>{name}</td>\
             <td class=\"num\">{qty}</td><td class=\"num\">{val}</td></tr>",
            inst = esc_html(&institution),
            acct = esc_html(&account),
            sym = esc_html(&symbol),
            name = esc_html(&holding_name),
            qty = quantity
                .map(|v| v.normalize().to_string())
                .unwrap_or_else(|| "—".to_string()),
            val = value
                .map(|v| format!("{} {}", money_grouped(v), esc_html(&currency)))
                .unwrap_or_else(|| "—".to_string()),
        ));
    }
    let holdings_section = if holdings_html.is_empty() {
        String::new()
    } else {
        format!(
            "<h2>{hdr}</h2><table><thead><tr><th>{inst}</th><th>{acct}</th>\
             <th class=\"st\">{sym}</th><th>{name}</th><th class=\"num\">{qty}</th>\
             <th class=\"num\">{val}</th></tr></thead><tbody>{rows}</tbody></table>",
            hdr = t("Holdings summary", "Resumen de inversiones"),
            inst = t("Institution", "Institución"),
            acct = t("Account", "Cuenta"),
            sym = t("Ticker", "Clave"),
            name = t("Name", "Nombre"),
            qty = t("Quantity", "Cantidad"),
            val = t("Last value", "Último valor"),
            rows = holdings_html,
        )
    };

    // ------------------------------------------------------------------
    // Lending book. Outstanding = principal − Σ principal repaid, floored
    // at zero, and zero for terminal statuses — the same derived-balance
    // rule api/loans.rs uses (the outstanding figure is never stored).
    // ------------------------------------------------------------------
    let loan_rows = sqlx::query(
        r#"
        SELECT l.borrower_name AS borrower, l.status AS status,
               l.currency AS currency, l.principal AS principal,
               l.origination_date AS origination_date,
               pe.note AS contact_note,
               COALESCE((SELECT SUM(COALESCE(p.principal_portion, p.paid_amount, 0))
                         FROM loan_payments p
                         WHERE p.loan_id = l.id AND p.paid_amount IS NOT NULL), 0)
                   AS principal_paid
        FROM loans l
        LEFT JOIN people pe ON pe.id = l.person_id AND pe.user_id = l.user_id
        WHERE l.user_id = $1
        ORDER BY (l.status = 'active') DESC, l.origination_date DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let mut loans_html = String::new();
    for r in &loan_rows {
        let borrower: String = r.try_get("borrower").unwrap_or_default();
        let status: String = r.try_get("status").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let principal: Decimal = r.try_get("principal").unwrap_or_default();
        let origination: Option<NaiveDate> = r.try_get("origination_date").ok().flatten();
        let contact_note: String = r.try_get("contact_note").unwrap_or_default();
        let principal_paid: Decimal = r.try_get("principal_paid").unwrap_or_default();
        let outstanding = if matches!(status.as_str(), "paid_off" | "written_off" | "cancelled") {
            Decimal::ZERO
        } else {
            (principal - principal_paid).max(Decimal::ZERO)
        };
        let status_label = match status.as_str() {
            "active" => t("Active", "Activo"),
            "paid_off" => t("Paid off", "Liquidado"),
            "written_off" => t("Written off", "Cancelado por pérdida"),
            "cancelled" => t("Cancelled", "Anulado"),
            _ => "",
        };
        loans_html.push_str(&format!(
            "<tr><td>{borrower}</td><td class=\"st\">{status}</td>\
             <td class=\"st\">{origination}</td><td class=\"st\">{ccy}</td>\
             <td class=\"num\">{principal}</td><td class=\"num\">{outstanding}</td>\
             <td>{contact}</td></tr>",
            borrower = esc_html(&borrower),
            status = if status_label.is_empty() {
                esc_html(&status)
            } else {
                status_label.to_string()
            },
            origination = origination.map(|d| d.to_string()).unwrap_or_default(),
            ccy = esc_html(&currency),
            principal = money_grouped(principal),
            outstanding = money_grouped(outstanding),
            contact = esc_html(&contact_note),
        ));
    }
    let lending_section = if loans_html.is_empty() {
        String::new()
    } else {
        format!(
            "<h2>{hdr}</h2><table><thead><tr><th>{who}</th><th class=\"st\">{status}</th>\
             <th class=\"st\">{orig}</th><th class=\"st\">{ccy}</th>\
             <th class=\"num\">{principal}</th><th class=\"num\">{outstanding}</th>\
             <th>{contact}</th></tr></thead><tbody>{rows}</tbody></table>\
             <p class=\"note\">{agreements}</p>",
            rows = loans_html,
            hdr = t("Personal lending book", "Libro de préstamos personales"),
            who = t("Borrower", "Prestatario"),
            status = t("Status", "Estado"),
            orig = t("Originated", "Otorgado"),
            ccy = t("Currency", "Moneda"),
            principal = t("Principal", "Capital"),
            outstanding = t("Outstanding", "Saldo pendiente"),
            contact = t("Contact note", "Nota de contacto"),
            agreements = t(
                "A printable promissory note / agreement exists for each loan inside the app: Lending → open the loan → Agreement.",
                "Dentro de la app existe un pagaré / convenio imprimible por cada préstamo: Préstamos → abrir el préstamo → Convenio."
            ),
        )
    };

    // ------------------------------------------------------------------
    // Render. Same printable skeleton as the FBAR worksheet (zero-margin
    // @page so the saved PDF has no browser header/footer).
    // ------------------------------------------------------------------
    let (en_cls, es_cls) = if es { ("", "on") } else { ("on", "") };
    let fbar_note = if foreign_count > 0 {
        format!(
            "<p class=\"note\">{}</p>",
            t(
                "Accounts marked \"Yes\" in the FBAR column are foreign/reportable per the app's FBAR monitor — if their aggregate maximum exceeds the FinCEN threshold, a Form 114 filing is due. The Tax screen has a dedicated FBAR worksheet export.",
                "Las cuentas marcadas \"Sí\" en la columna FBAR son extranjeras/reportables según el monitor FBAR de la app — si su máximo agregado supera el umbral de FinCEN, corresponde presentar el Formulario 114. La pantalla de impuestos tiene una hoja de trabajo FBAR exportable."
            )
        )
    } else {
        String::new()
    };

    let html = format!(
        r#"<!DOCTYPE html><html lang="{doc_lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  :root {{ --ink:#1f2933; --muted:#6b7280; --line:#e5e7eb; --accent:#0f766e; --soft:#f0fdfa; --bg:#ffffff; }}
  * {{ box-sizing: border-box; }}
  body {{ font-family: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 980px; margin: 0 auto; color: var(--ink); line-height: 1.55; padding: 24px 20px 64px; background: var(--bg); }}
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
  .card .val {{ font-size:18px; font-weight:800; margin-top:4px; font-variant-numeric: tabular-nums; }}
  .card.accent {{ background:var(--soft); border-color:#99f6e4; }}
  .card.accent .val {{ color:var(--accent); }}
  table {{ width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 8px; }}
  thead th {{ background:var(--soft); color:var(--accent); text-align:left; padding:7px 8px; border-bottom:2px solid #99f6e4; font-size:10px; text-transform:uppercase; letter-spacing:.05em; }}
  tbody td {{ padding:6px 8px; border-bottom:1px solid var(--line); }}
  tbody tr:nth-child(even) {{ background:#fafafa; }}
  td.num, th.num {{ text-align:right; font-variant-numeric: tabular-nums; white-space:nowrap; }}
  td.st, th.st {{ text-align:center; white-space:nowrap; }}
  td.empty {{ color:var(--muted); text-align:center; padding:18px 10px; }}
  .notes {{ white-space: pre-wrap; border:1px solid var(--line); border-radius:12px; padding:14px 16px; font-size:13px; background:#fafafa; }}
  .empty-note {{ color:var(--muted); font-size:13px; }}
  .note {{ margin-top: 12px; font-size: 11px; color: var(--muted); }}
  .footer {{ margin-top: 28px; font-size: 11px; color: var(--muted); border-top:1px solid var(--line); padding-top:12px; }}
  @media (max-width: 520px) {{ .cards {{ grid-template-columns: 1fr; }} }}
  /* Zero @page margins suppress the browser's print header/footer; the
     document supplies its own margins via body padding (loan-printable
     convention), so the saved PDF is clean. */
  @page {{ margin: 0; }}
  @media print {{ body {{ padding: 16mm 14mm 18mm; }} .tools {{ display:none; }} .card, thead th {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }} }}
</style></head><body>
<div class="topbar">
  <span class="brand">Patrimonio</span>
  <div class="tools">
    <span class="lang"><a href="?lang=en" class="{en_cls}">EN</a><a href="?lang=es" class="{es_cls}">ES</a></span>
    <button class="print" onclick="window.print()">{print}</button>
  </div>
</div>
<h1>{title}</h1>
<p class="subtitle">{subtitle}</p>

<div class="cards">
  <div class="card accent"><div class="k">{asof_lbl}</div><div class="val">{asof_val}</div></div>
  <div class="card"><div class="k">{gen_lbl}</div><div class="val">{gen_val}</div></div>
  <div class="card"><div class="k">{count_lbl}</div><div class="val">{count_val}</div></div>
</div>
<p class="note">{no_secrets}</p>

<h2>{notes_hdr}</h2>
{notes_html}

<h2>{accounts_hdr}</h2>
<table>
  <thead><tr>
    <th>{col_inst}</th><th>{col_acct}</th><th class="st">{col_type}</th>
    <th class="st">{col_country}</th><th class="st">{col_ccy}</th>
    <th class="st">{col_integ}</th><th class="num">{col_bal}</th>
    <th class="num">{col_usd}</th><th class="st">{col_asof}</th>
    <th class="st">{col_fbar}</th>
  </tr></thead>
  <tbody>{accounts_html}</tbody>
</table>
{fbar_note}
{valuations_section}
{holdings_section}
{lending_section}
<p class="footer">{disclaimer}</p>
</body></html>"#,
        doc_lang = if es { "es" } else { "en" },
        title = t(
            "Household continuity dossier",
            "Expediente de continuidad del hogar"
        ),
        subtitle = t(
            "A printable inventory of every institution, account, balance, holding, and personal loan tracked in Patrimonio — for the household member or executor who has to take over. Print it, date it, and keep it with the estate documents.",
            "Un inventario imprimible de cada institución, cuenta, saldo, inversión y préstamo personal registrado en Patrimonio — para el familiar o albacea que deba hacerse cargo. Imprímelo, féchalo y guárdalo con los documentos del patrimonio."
        ),
        print = t("Print / Save as PDF", "Imprimir / Guardar como PDF"),
        asof_lbl = t("Data as of", "Datos al"),
        asof_val = data_as_of_str,
        gen_lbl = t("Generated", "Generado"),
        gen_val = generated_str,
        count_lbl = t("Accounts listed", "Cuentas listadas"),
        count_val = account_rows.len(),
        no_secrets = t(
            "This document deliberately contains NO passwords, tokens, or credentials — only names and balances. Access credentials live wherever the owner keeps them (password manager, estate documents); institutions will require legal documentation to grant access.",
            "Este documento deliberadamente NO contiene contraseñas, tokens ni credenciales — solo nombres y saldos. Las credenciales de acceso están donde el titular las guarde (gestor de contraseñas, documentos del patrimonio); las instituciones exigirán documentación legal para dar acceso."
        ),
        notes_hdr = t("Owner's instructions", "Instrucciones del titular"),
        // Static template string — pre-escaped ampersand, not user data.
        accounts_hdr = t("Institutions &amp; accounts", "Instituciones y cuentas"),
        col_inst = t("Institution", "Institución"),
        col_acct = t("Account", "Cuenta"),
        col_type = t("Type", "Tipo"),
        col_country = t("Country", "País"),
        col_ccy = t("Currency", "Moneda"),
        col_integ = t("Source", "Origen"),
        col_bal = t("Last balance", "Último saldo"),
        col_usd = t("USD", "USD"),
        col_asof = t("As of", "Al"),
        col_fbar = t("FBAR", "FBAR"),
        disclaimer = t(
            "Generated by Patrimonio from stored data as a continuity aid — informational only, not legal or tax advice. Balances are the app's last known figures and go stale the moment this page is printed; regenerate the dossier periodically (each January, after FBAR season, works well).",
            "Generado por Patrimonio a partir de los datos almacenados como apoyo de continuidad — solo informativo, no es asesoría legal ni fiscal. Los saldos son las últimas cifras conocidas por la app y quedan desactualizados en cuanto se imprime esta página; regenera el expediente periódicamente (cada enero, después de la temporada FBAR, funciona bien)."
        ),
    );

    Ok((
        [(header::CONTENT_TYPE, "text/html; charset=utf-8".to_string())],
        html,
    )
        .into_response())
}
