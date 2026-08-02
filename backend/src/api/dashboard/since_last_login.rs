use axum::{
    extract::{Extension, State},
    Json,
};
use serde::Serialize;
use sqlx::Row;

use crate::api::middleware::AuthContext;
use crate::AppState;

/// How long a gap in dashboard activity ends one visit and starts the next.
///
/// Long enough that flipping between tabs, pulling to refresh, or coming
/// back after lunch stays a single visit (so the summary you were reading
/// doesn't reset itself out from under you); short enough that "this
/// morning" and "this evening" count as two, which is the granularity the
/// banner's "what happened while you were away" framing implies.
const VISIT_GAP_HOURS: i32 = 4;

#[derive(Serialize)]
pub(super) struct SinceLastLogin {
    /// ISO-8601 timestamp of the anchor: when the visit BEFORE this one
    /// ended. `None` when the user has no recorded visit and has never
    /// logged in twice — the banner stays hidden in that case so a fresh
    /// user doesn't see "0 since never".
    ///
    /// Still named `previous_login_at` on the wire: it is the key the web
    /// banner and the shipped APK dismiss on (`Preferences
    /// .dismissSinceLastLoginFor`), and renaming it would silently
    /// un-dismiss banners on every client that hasn't updated. The name is
    /// a fossil of the old login anchor; the meaning is the visit anchor.
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_login_at: Option<String>,
    /// Count of new transactions across all of this user's accounts
    /// since `previous_login_at`. Counts rows whose `created_at` is
    /// after that timestamp — Plaid sync stamps `created_at` at insert
    /// time so this correctly reflects "what the sync engine has
    /// produced since you were last here," not "what dates the bank
    /// stamped on them."
    new_transactions: i64,
    /// Largest absolute balance move on any single account since the
    /// anchor, in USD. `None` when no two snapshots straddle the anchor
    /// (insufficient history).
    #[serde(skip_serializing_if = "Option::is_none")]
    largest_move: Option<BalanceMove>,
    /// Names of institutions whose `sync_status` flipped to a problem
    /// state since the anchor. Used for "Chase needs reconnecting" call-outs.
    sync_errors: Vec<String>,
}

#[derive(Serialize)]
struct BalanceMove {
    account_name: String,
    delta_usd: f64,
    /// The moved account's id (uuid as text). Additive field so the
    /// client can scope its "show me the transactions" drill-down to the
    /// account, not just the date window; older clients simply ignore it.
    account_id: String,
    /// The moved account's institution name, when it has one. Additive:
    /// generic nicknames ("Cards", "Checking") recur across banks, so
    /// the client disambiguates the headline as "Cards · SoFi". Omitted
    /// (not null) for accounts without an institution so older clients
    /// and institution-less accounts see the payload they always did.
    #[serde(skip_serializing_if = "Option::is_none")]
    institution_name: Option<String>,
}

/// "What changed since your last visit." Anchors on the end of the previous
/// VISIT (`users.previous_visit_at`), falling back to `previous_login_at` for
/// a user with no recorded visit yet. When there is neither, the entire
/// response is suppressed so a fresh user doesn't see a useless "0 since
/// never" banner.
///
/// Anchoring on the login was wrong for the way the app is actually used:
/// a session survives for weeks, so a phone that is opened daily still
/// reported everything since the last time its owner typed a password —
/// "143 new transactions since your last visit · Jul 13" on Jul 30. The
/// anchor now tracks visits, which is what the copy claims and what the
/// bell's "new transactions" / "largest move" rows mean too (they render
/// this same payload).
///
/// This GET has a deliberate write: listing what changed since the last
/// visit IS the visit, so it is the honest place to record one. The roll is
/// a single UPDATE … RETURNING, so two devices loading the dashboard at once
/// can't interleave a read with a write and both claim the same anchor.
pub(super) async fn since_last_login(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<SinceLastLogin> {
    // Start a new visit only after a real gap; otherwise hold the anchor
    // still, so a refresh (or the second dashboard load of the same
    // sitting) doesn't wipe the summary the user is in the middle of
    // reading. `previous_login_at` covers users migrated before visits
    // were tracked and users who have logged in twice but never been
    // seen here.
    let anchor_row = sqlx::query(
        "UPDATE users \
            SET previous_visit_at = CASE \
                    WHEN last_visit_at IS NULL THEN previous_visit_at \
                    WHEN last_visit_at < NOW() - ($2 * INTERVAL '1 hour') \
                        THEN last_visit_at \
                    ELSE previous_visit_at \
                END, \
                last_visit_at = NOW() \
          WHERE id = $1 \
      RETURNING COALESCE(previous_visit_at, previous_login_at) AS anchor",
    )
    .bind(ctx.user_id)
    .bind(VISIT_GAP_HOURS)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    let anchor: Option<chrono::DateTime<chrono::Utc>> =
        anchor_row.and_then(|r| r.try_get::<chrono::DateTime<chrono::Utc>, _>("anchor").ok());

    let Some(anchor) = anchor else {
        return Json(SinceLastLogin {
            previous_login_at: None,
            new_transactions: 0,
            largest_move: None,
            sync_errors: vec![],
        });
    };

    // 1) New transactions count. We count by `created_at` — what the sync
    //    engine added — rather than by transaction `date`, because Plaid
    //    can backfill old dates and the user would care most about "new
    //    rows that appeared in my list since I was last here."
    let tx_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM transactions t \
         WHERE t.user_id = $1 AND t.created_at > $2 \
           AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)",
    )
    .bind(ctx.user_id)
    .bind(anchor)
    .fetch_one(&state.db)
    .await
    .unwrap_or(0);

    // 2) Largest single-account balance move. Compare each account's
    //    most recent snapshot at or after the anchor against the most
    //    recent one strictly before the anchor. Skip accounts that
    //    don't have a "before" snapshot — for a newly-linked account
    //    we'd otherwise count the whole balance as a "move."
    //
    //    Sign convention: positive delta means net worth went up.
    //    Liability balances are flipped — a credit card going $500 → $1500
    //    is a $1000 increase in what you owe, i.e. -$1000 to net worth.
    let moves = sqlx::query(
        r#"
        WITH before AS (
            SELECT DISTINCT ON (bs.account_id) bs.account_id, bs.balance_usd
            FROM balance_snapshots bs
            WHERE bs.user_id = $1 AND bs.created_at <= $2
            ORDER BY bs.account_id, bs.created_at DESC
        ),
        after AS (
            SELECT DISTINCT ON (bs.account_id) bs.account_id, bs.balance_usd
            FROM balance_snapshots bs
            WHERE bs.user_id = $1 AND bs.created_at > $2
            ORDER BY bs.account_id, bs.created_at DESC
        )
        SELECT
            COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
            -- uuid as text so the row decodes without a Uuid column type
            after.account_id::text AS account_id,
            -- LEFT JOIN: manual accounts can have no institution; the
            -- client falls back to the account name alone.
            i.name AS institution_name,
            CASE WHEN is_liability_account_type(a.account_type)
                 THEN -(after.balance_usd - before.balance_usd)
                 ELSE (after.balance_usd - before.balance_usd)
            END AS delta_usd
        FROM after
        JOIN before ON before.account_id = after.account_id
        JOIN accounts a ON a.id = after.account_id
        LEFT JOIN institutions i ON a.institution_id = i.id
        WHERE a.user_id = $1 AND a.archived_at IS NULL
        "#,
    )
    .bind(ctx.user_id)
    .bind(anchor)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let largest_move = moves
        .iter()
        .filter_map(|r| {
            let name: String = r.try_get("account_name").ok()?;
            let account_id: String = r.try_get("account_id").ok()?;
            // NULL (no institution) decodes to None → the key is
            // omitted from the JSON (skip_serializing_if).
            let institution_name: Option<String> = r
                .try_get::<Option<String>, _>("institution_name")
                .ok()
                .flatten();
            let delta: rust_decimal::Decimal = r.try_get("delta_usd").ok()?;
            let delta_f: f64 = delta.to_string().parse().ok()?;
            Some(BalanceMove {
                account_name: name,
                delta_usd: delta_f,
                account_id,
                institution_name,
            })
        })
        .max_by(|a, b| {
            a.delta_usd
                .abs()
                .partial_cmp(&b.delta_usd.abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        // A delta < $1 is noise (rounding, sub-dollar FX drift); hide it.
        .filter(|m| m.delta_usd.abs() >= 1.0);

    // 3) Institutions that have an error or reconnect_required status
    //    whose last sync error landed AFTER the anchor. We approximate
    //    with the row's `last_synced_at` since that's the only timestamp
    //    we keep — a more accurate "errored since" timestamp would
    //    require a separate column.
    let sync_errors: Vec<String> = sqlx::query(
        "SELECT name FROM institutions \
         WHERE user_id = $1 \
           AND sync_status IN ('error', 'reconnect_required') \
           AND (last_synced_at IS NULL OR last_synced_at >= $2)",
    )
    .bind(ctx.user_id)
    .bind(anchor)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default()
    .iter()
    .filter_map(|r| r.try_get::<String, _>("name").ok())
    .collect();

    Json(SinceLastLogin {
        previous_login_at: Some(anchor.to_rfc3339()),
        new_transactions: tx_count,
        largest_move,
        sync_errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// FIX-2 serialization contract: `institution_name` is additive with
    /// `skip_serializing_if = "Option::is_none"` — an account without an
    /// institution (None) omits the key entirely rather than sending
    /// null, so older clients see the payload they always did. The
    /// present-and-correct half is covered end-to-end by the
    /// `since_last_login_largest_move_carries_account_id` integration
    /// test; the omission half lives here because accounts.institution_id
    /// is NOT NULL and the None branch can't be seeded through the DB.
    #[test]
    fn balance_move_omits_absent_institution_name() {
        let without = serde_json::to_value(BalanceMove {
            account_name: "Cards".to_string(),
            delta_usd: 2612.87,
            account_id: "6e9c1a4e-0000-0000-0000-000000000001".to_string(),
            institution_name: None,
        })
        .expect("serialize");
        assert!(
            without.get("institution_name").is_none(),
            "None must omit the key, not serialize null: {without}"
        );

        let with = serde_json::to_value(BalanceMove {
            account_name: "Cards".to_string(),
            delta_usd: 2612.87,
            account_id: "6e9c1a4e-0000-0000-0000-000000000001".to_string(),
            institution_name: Some("SoFi".to_string()),
        })
        .expect("serialize");
        assert_eq!(with["institution_name"], "SoFi");
    }
}
