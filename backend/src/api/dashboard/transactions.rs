use axum::{
    extract::{Extension, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::error;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

/// Recent transactions across all accounts. `limit` defaults to 50 and is
/// capped at 500 to keep one response cheap; `offset` lets the frontend
/// page through the rest with a 'Load more' button.
///
/// The optional `currency`, `sign`, and `q` filters let a caller scope the
/// list server-side instead of pulling a page and filtering in the client.
/// The loan-repayment picker relies on this: it must search the WHOLE table
/// (a repayment can be older than one page), scoped to the loan's currency
/// (a foreign-currency inflow would be rejected at reconcile time) and to
/// inflows only. Doing that here means the client no longer misses a match
/// that fell outside the newest-N window.
#[derive(Deserialize)]
pub(super) struct TransactionsQuery {
    limit: Option<i64>,
    offset: Option<i64>,
    /// ISO currency code; scopes the list to that currency when present.
    currency: Option<String>,
    /// `"inflow"` (amount > 0) or `"outflow"` (amount < 0). Any other value
    /// (or absent) applies no sign filter.
    sign: Option<String>,
    /// Case-insensitive substring matched across the transaction's text
    /// columns, in SQL, so a hit is found regardless of recency/paging.
    q: Option<String>,
    /// When true, drop transactions already reconciled to a loan (a linked
    /// repayment or a linked disbursement). The loan payment picker sets it
    /// so it never offers a tx that would only be rejected as "already
    /// linked" on submit.
    exclude_linked: Option<bool>,
}

pub(super) async fn recent_transactions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TransactionsQuery>,
) -> impl IntoResponse {
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    let offset = query.offset.unwrap_or(0).max(0);
    // Empty strings arrive from `?currency=&q=` — treat them as absent so
    // the nullable-parameter filters below short-circuit to "no filter".
    let currency = query.currency.filter(|s| !s.trim().is_empty());
    let sign = query.sign.filter(|s| !s.trim().is_empty());
    let search = query.q.filter(|s| !s.trim().is_empty());
    let exclude_linked = query.exclude_linked.unwrap_or(false);
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.account_id,
               -- Total matching rows BEFORE LIMIT/OFFSET. The window
               -- function runs over the identical WHERE (user scope,
               -- split-parent exclusion, currency/sign/q/exclude_linked)
               -- with zero clause duplication, so the X-Total-Count header
               -- can never drift from the list contract and is identical
               -- on every page.
               COUNT(*) OVER () AS total_count,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name,
               t.amount, t.currency,
               t.date, t.description, t.category, t.category_detailed,
               t.payment_channel, t.merchant_name,
               t.original_description, t.counterparty_name, t.counterparty_logo_url,
               t.user_description, t.user_category, t.user_notes,
               t.payment_payee, t.payment_payer,
               t.parent_id,
               t.pending,
               t.source,
               t.created_at
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          AND ($4::text IS NULL OR t.currency = $4)
          -- Unknown/absent sign → no filter; only the two known values bite.
          AND ($5::text IS NULL
               OR $5 NOT IN ('inflow', 'outflow')
               OR ($5 = 'inflow' AND t.amount > 0)
               OR ($5 = 'outflow' AND t.amount < 0))
          AND ($6::text IS NULL
               OR t.description ILIKE '%' || $6 || '%'
               OR t.merchant_name ILIKE '%' || $6 || '%'
               OR t.counterparty_name ILIKE '%' || $6 || '%'
               OR t.original_description ILIKE '%' || $6 || '%')
          -- Hide transactions already reconciled to a loan (either leg) when
          -- the caller asks — the payment picker does, so it can't offer a
          -- tx the reconcile step would reject.
          AND (NOT $7 OR (
                NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
            AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          ))
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $2 OFFSET $3
        "#,
    )
    .bind(ctx.user_id)
    .bind(limit)
    .bind(offset)
    .bind(currency)
    .bind(sign)
    .bind(search)
    .bind(exclude_linked)
    .fetch_all(&state.db)
    .await;

    // Best-effort read semantics unchanged: a DB error still yields an
    // empty 200 array with no header — but remember Result-ness first,
    // because "the query succeeded and found nothing" is meaningful below.
    let db_ok = rows.is_ok();
    let rows = rows.unwrap_or_default();

    // The window total is the same on every row; read it off the first.
    // A successful empty FIRST page (offset == 0) provably means the
    // filtered total is 0 — emit it so the client can clear a stale
    // "Showing 0 of N" after deleting its last rows. An empty page beyond
    // the end (offset > 0) proves nothing about the total → no header.
    let total = rows
        .first()
        .and_then(|r| r.try_get::<i64, _>("total_count").ok())
        .or((db_ok && offset == 0).then_some(0));

    let entries: Vec<TransactionEntry> = rows
        .iter()
        .map(|r| {
            let amount: f64 = r
                .try_get::<rust_decimal::Decimal, _>("amount")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            TransactionEntry {
                id: r.get::<uuid::Uuid, _>("id").to_string(),
                account_id: r.get::<uuid::Uuid, _>("account_id").to_string(),
                account_name: r.get("account_name"),
                institution_name: r
                    .try_get::<Option<String>, _>("institution_name")
                    .ok()
                    .flatten(),
                amount,
                currency: r.get("currency"),
                date: r.get::<chrono::NaiveDate, _>("date").to_string(),
                description: r.get("description"),
                category: r.get("category"),
                category_detailed: r
                    .try_get::<Option<String>, _>("category_detailed")
                    .ok()
                    .flatten(),
                payment_channel: r
                    .try_get::<Option<String>, _>("payment_channel")
                    .ok()
                    .flatten(),
                merchant_name: r
                    .try_get::<Option<String>, _>("merchant_name")
                    .ok()
                    .flatten(),
                original_description: r
                    .try_get::<Option<String>, _>("original_description")
                    .ok()
                    .flatten(),
                counterparty_name: r
                    .try_get::<Option<String>, _>("counterparty_name")
                    .ok()
                    .flatten(),
                counterparty_logo_url: r
                    .try_get::<Option<String>, _>("counterparty_logo_url")
                    .ok()
                    .flatten(),
                user_description: r
                    .try_get::<Option<String>, _>("user_description")
                    .ok()
                    .flatten(),
                user_category: r
                    .try_get::<Option<String>, _>("user_category")
                    .ok()
                    .flatten(),
                user_notes: r.try_get::<Option<String>, _>("user_notes").ok().flatten(),
                payment_payee: r
                    .try_get::<Option<String>, _>("payment_payee")
                    .ok()
                    .flatten(),
                payment_payer: r
                    .try_get::<Option<String>, _>("payment_payer")
                    .ok()
                    .flatten(),
                parent_id: r
                    .try_get::<Option<uuid::Uuid>, _>("parent_id")
                    .ok()
                    .flatten()
                    .map(|u| u.to_string()),
                pending: r.get("pending"),
                source: r.try_get::<Option<String>, _>("source").ok().flatten(),
                created_at: r
                    .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("created_at")
                    .ok()
                    .flatten()
                    .map(|dt| dt.to_rfc3339())
                    .unwrap_or_default(),
            }
        })
        .collect();

    (total_count_headers(total), Json(entries))
}

/// CSV export of every transaction across all accounts. Streams the
/// whole table — useful for an annual tax-prep dump. We escape
/// quotes/commas by wrapping every text field in double quotes and
/// doubling any embedded double quote.
/// Streams the user's transactions as CSV. Both ends of the pipe
/// are streaming:
///   * The DB query uses `.fetch(...)` (not `.fetch_all`) so sqlx
///     hands us rows one at a time instead of buffering the whole
///     result set in memory.
///   * The response body is an `mpsc::channel` wrapped in a
///     `ReceiverStream` and handed to `axum::body::Body::from_stream`,
///     so each row's bytes leave the server the moment they're
///     formatted — no `String` buffer holding the entire CSV.
///
/// Net effect: a 50k-row export now fits in O(channel_buffer * row_size)
/// memory instead of O(row_count * row_size × ~5 with CSV overhead).
/// Audit P4.
pub(super) async fn export_transactions_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    use bytes::Bytes;
    use futures_util::StreamExt;

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio-transactions-{today}.csv");

    // The channel-buffer of 16 lets the writer get ahead of the
    // socket without holding the whole CSV in RAM. Bigger is
    // faster on a fast link, but 16 chunks × ~256 bytes/row is a
    // ~4 KB ceiling — already plenty for a TCP send buffer to
    // drain into.
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);
    let db = state.db.clone();
    let user_id = ctx.user_id;

    tokio::spawn(async move {
        fn esc(s: &str) -> String {
            format!("\"{}\"", s.replace('"', "\"\""))
        }

        // Header row first. A send failure here means the client
        // already disconnected — abort cleanly without spending DB
        // work on a request nobody is reading.
        if tx
            .send(Ok(Bytes::from_static(
                b"id,date,account,institution,description,merchant,category,category_detailed,payment_channel,amount,currency,source,pending\n",
            )))
            .await
            .is_err()
        {
            return;
        }

        let mut stream = sqlx::query(
            r#"
            SELECT t.id, t.date, t.amount, t.currency, t.description,
                   COALESCE(t.category, '') as category,
                   COALESCE(t.category_detailed, '') as category_detailed,
                   COALESCE(t.payment_channel, '') as payment_channel,
                   COALESCE(t.merchant_name, '') as merchant_name,
                   COALESCE(t.source, '') as source,
                   t.pending,
                   COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
                   COALESCE(i.name, '') as institution_name
            FROM transactions t
            JOIN accounts a ON t.account_id = a.id
            JOIN institutions i ON a.institution_id = i.id
            WHERE t.user_id = $1
              AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
            ORDER BY t.date DESC, t.created_at DESC
            "#,
        )
        .bind(user_id)
        .fetch(&db);

        while let Some(row_result) = stream.next().await {
            let row = match row_result {
                Ok(r) => r,
                Err(e) => {
                    error!("export_transactions_csv stream error: {}", e);
                    // Surface the failure to the client as an io
                    // error — axum will close the body with an
                    // error frame and downstream tools (curl, the
                    // browser download) will report the truncation
                    // instead of silently shipping a half CSV.
                    let _ = tx
                        .send(Err(std::io::Error::other(format!("csv stream: {e}"))))
                        .await;
                    return;
                }
            };
            let id: uuid::Uuid = row.get("id");
            let date: chrono::NaiveDate = row.get("date");
            let amount: rust_decimal::Decimal = row.get("amount");
            let currency: String = row.get("currency");
            let description: String = row.get("description");
            let category: String = row.get("category");
            let category_detailed: String = row.get("category_detailed");
            let payment_channel: String = row.get("payment_channel");
            let merchant: String = row.get("merchant_name");
            let source: String = row.get("source");
            let pending: bool = row.get("pending");
            let account_name: String = row.get("account_name");
            let institution_name: String = row.get("institution_name");
            let line = format!(
                "{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
                id,
                date,
                esc(&account_name),
                esc(&institution_name),
                esc(&description),
                esc(&merchant),
                esc(&category),
                esc(&category_detailed),
                esc(&payment_channel),
                amount,
                currency,
                esc(&source),
                pending,
            );
            if tx.send(Ok(Bytes::from(line))).await.is_err() {
                // Client dropped. Stop the loop so we don't keep
                // pulling rows that will never ship.
                return;
            }
        }
    });

    let body = axum::body::Body::from_stream(tokio_stream::wrappers::ReceiverStream::new(rx));

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/csv; charset=utf-8")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{filename}\""),
        )
        .body(body)
        .unwrap()
}

#[derive(Deserialize)]
pub(super) struct CreateManualTransactionRequest {
    account_id: uuid::Uuid,
    date: chrono::NaiveDate,
    description: String,
    /// Negative numbers are outflows (expenses), positive are inflows
    /// (income). Matches the Plaid sync path in
    /// `services/sync.rs`, which negates Plaid's outflow-positive
    /// amounts on import, and `cash_flow_trends` which sums
    /// `amount > 0` as income.
    amount: rust_decimal::Decimal,
    currency: String,
    #[serde(default)]
    category: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

/// Add a transaction the user typed in themselves (cash purchases,
/// gifts, anything Plaid never sees). Reuses the same row shape as
/// imported transactions; only the `source` field differentiates them.
pub(super) async fn create_manual_transaction(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<CreateManualTransactionRequest>,
) -> Response {
    // Verify the target account belongs to this caller before
    // creating a transaction against it — otherwise an attacker
    // could plant rows on a victim's account.
    let owns = sqlx::query("SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(payload.account_id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    if !matches!(owns, Ok(Some(_))) {
        return StatusCode::NOT_FOUND.into_response();
    }

    // Deterministic external_id so a duplicate manual entry (same date /
    // amount / description on the same account) collapses to one row
    // instead of stacking up if the user double-submits.
    let signature = format!(
        "manual:{}:{}:{}",
        payload.date,
        payload.amount,
        payload
            .description
            .to_lowercase()
            .chars()
            .take(50)
            .collect::<String>()
    );
    let result = sqlx::query(
        r#"
        INSERT INTO transactions
            (account_id, external_id, date, description, amount, currency, category, source, source_id, user_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'manual', 'manual_add', $8)
        ON CONFLICT (account_id, external_id) DO NOTHING
        RETURNING id
        "#,
    )
    .bind(payload.account_id)
    .bind(&signature)
    .bind(payload.date)
    .bind(&payload.description)
    .bind(payload.amount)
    .bind(&payload.currency)
    .bind(&payload.category)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    match result {
        Ok(Some(row)) => {
            let id: uuid::Uuid = row.get("id");
            if let Some(notes) = payload.notes.as_ref().filter(|n| !n.is_empty()) {
                let _ = sqlx::query(
                    "UPDATE transactions SET user_notes = $1 WHERE id = $2 AND user_id = $3",
                )
                .bind(notes)
                .bind(id)
                .bind(ctx.user_id)
                .execute(&state.db)
                .await;
            }
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            (
                StatusCode::CREATED,
                Json(serde_json::json!({"id": id.to_string()})),
            )
                .into_response()
        }
        Ok(None) => (StatusCode::CONFLICT, "duplicate manual transaction").into_response(),
        Err(e) => {
            error!("Failed to insert manual transaction: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, "insert failed").into_response()
        }
    }
}

#[derive(Serialize)]
struct TransactionEntry {
    id: String,
    account_id: String,
    account_name: String,
    /// Owning institution (e.g. "Capital One", "Chase"). Surfaced so the
    /// activity list and detail panel can disambiguate generic account
    /// labels like "Checking ••0916" — which on its own reads as an
    /// unknown account.
    #[serde(skip_serializing_if = "Option::is_none")]
    institution_name: Option<String>,
    amount: f64,
    currency: String,
    date: String,
    description: String,
    category: Option<String>,
    /// Plaid's `personal_finance_category.detailed` — much more specific
    /// than `category` (e.g. "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" vs
    /// just "LOAN_PAYMENTS"). The frontend prefers this when set.
    #[serde(skip_serializing_if = "Option::is_none")]
    category_detailed: Option<String>,
    /// "online" / "in_store" / "other" / "bank" — surfaced as a small
    /// chip alongside the category in the detail panel.
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_channel: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    merchant_name: Option<String>,
    /// Raw bank line — survives when Plaid's cleaned `description`
    /// falls back to "Miscellaneous Debit" or similar generic label.
    #[serde(skip_serializing_if = "Option::is_none")]
    original_description: Option<String>,
    /// Best counterparty from Plaid's enriched `counterparties[]` array.
    /// Preferred over `merchant_name` and `description` for display.
    #[serde(skip_serializing_if = "Option::is_none")]
    counterparty_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    counterparty_logo_url: Option<String>,
    /// User-supplied display label, preferred by `displayLabel` over
    /// every Plaid-side fallback when set.
    #[serde(skip_serializing_if = "Option::is_none")]
    user_description: Option<String>,
    /// User category override — the list/detail surfaces display this
    /// over the raw `category` when set. Deliberately NOT skipped when
    /// absent so this feed matches the per-account feed's shape
    /// (`TransactionResponse` in api/accounts.rs): omitting these two
    /// fields once made the edit dialog prefill from nulls and the
    /// subsequent PUT silently wipe a saved note (real data loss).
    user_category: Option<String>,
    /// Free-form user note. Same no-skip rationale as `user_category` —
    /// the edit dialog prefills from this field, so the feed must carry
    /// the stored value, not leave the client to guess null.
    user_notes: Option<String>,
    /// Plaid `payment_meta.payee` — for ACH/wire/bill-pay rows where the
    /// bank's `name` is "Miscellaneous Debit" but the payee is the only
    /// useful identifier (e.g. "PG&E", "VERIZON").
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_payee: Option<String>,
    /// Plaid `payment_meta.payer` — symmetric to `payment_payee` for
    /// incoming wires/ACH where Plaid identifies who sent the funds.
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_payer: Option<String>,
    /// When non-null, this transaction is a child of a split. Display
    /// hint only — children aggregate exactly like regular transactions.
    #[serde(skip_serializing_if = "Option::is_none")]
    parent_id: Option<String>,
    pending: bool,
    /// Provenance: 'plaid' | 'csv' | 'manual' | 'split' (see the
    /// `transactions.source` column). Deliberately NOT skipped when
    /// absent — the frontend must never have to guess provenance
    /// (assuming 'plaid' put a "Synced via Plaid" chip on hand-typed
    /// rows); a null here renders as an explicit "unknown" state.
    source: Option<String>,
    /// RFC3339 instant the row was INSERTED (sync/import/manual-add time),
    /// as opposed to `date` — the bank-POSTED day. The since-last-visit
    /// drill-down filters on this: card transactions post days before the
    /// sync fetches them, so "new since Jul 31" rows can all be DATED
    /// Jul 28–30 and no posted-date window can ever show them faithfully.
    /// Empty string only if the column were somehow NULL (pre-default row).
    created_at: String,
}
