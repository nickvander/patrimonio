//! Staleness reminders for import-only institutions.
//!
//! Plaid/exchange-linked institutions refresh themselves; institutions with
//! `integration_type = 'manual'` only move when the user imports a CSV/PDF
//! statement (or edits a balance by hand). This module derives "days since
//! last import" from data we already store — no schema change:
//!
//! - `accounts.updated_at` bumps on every import confirm and manual balance
//!   edit (and on rename — a rare, self-correcting false-fresh), and
//! - `MAX(transactions.created_at)` is the wall-clock time the last statement
//!   row landed (NOT the transaction's own historical `date`).
//!
//! ⚠ `balance_snapshots.created_at` is deliberately NOT a freshness signal:
//! the daily snapshot cron writes a carry-forward row for EVERY account every
//! night, so its timestamp is always "today" regardless of when the user last
//! imported anything.
//!
//! The daily cron calls [`record_staleness_notifications`], which writes a
//! `user_notifications` row (kind = `import_stale`) once per staleness
//! episode: a second cron run stays silent, and a fresh import re-arms the
//! reminder because the dedup window is keyed on the institution's
//! last-data timestamp.
//!
//! Writing the row is only half the contract. A stored reminder is a claim
//! about the *present* ("CetesDirecto data is 45 days old"), so it has to be
//! retired when that stops being true — otherwise importing a statement
//! clears the dashboard banner while the bell keeps repeating the old number
//! forever. [`resolve_stale_import_notifications`] runs on every inbox read
//! and, for each manual institution, either deletes its reminder (fresh data
//! landed / muted / snoozed — i.e. the sweep would no longer create one) or
//! refreshes the day count in a reminder that is still true. The invariant:
//! **an `import_stale` row exists exactly while the institution would banner,
//! and its body always names today's age.**

use std::collections::{HashMap, HashSet};

use anyhow::Result;
use chrono::{DateTime, Duration, Utc};
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Default reminder threshold when the user hasn't configured one.
pub const DEFAULT_STALENESS_DAYS: i64 = 30;

/// `app_settings` key holding the per-user threshold (a JSON number of days).
/// The frontend Settings stepper writes the same key via `PUT /api/settings`.
pub const STALENESS_SETTING_KEY: &str = "import_staleness_days";

/// `app_settings` key holding per-institution snoozes: a JSON object mapping
/// institution id → `{"until": rfc3339, "data_as_of": rfc3339}`. Written by
/// the banner's dismiss (×) via the generic `PUT /api/settings` — the same
/// pattern as the frontend's `sync_banner_snooze` — and read here so the
/// daily sweep and the banner always agree on what's snoozed.
pub const STALENESS_SNOOZE_SETTING_KEY: &str = "import_staleness_snoozes";

/// `app_settings` key holding permanently muted institutions: a JSON array
/// of institution id strings ("Remind me" toggled off in Settings). Muted
/// institutions never banner and never get notification rows; the accounts
/// list "as of" chips are deliberately NOT muted (data honesty stays).
pub const STALENESS_MUTE_SETTING_KEY: &str = "import_staleness_muted";

/// `user_notifications.kind` for staleness reminders.
pub const STALENESS_NOTIFICATION_KIND: &str = "import_stale";

/// One institution's active dismiss window, parsed from
/// [`STALENESS_SNOOZE_SETTING_KEY`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StalenessSnooze {
    /// Reminders stay silent until this instant (dismiss time + 7 days).
    pub until: DateTime<Utc>,
    /// The institution's `last_data_at` at dismiss time. A fresh import
    /// moves the live `last_data_at` past this marker, which invalidates
    /// the snooze (new data = new staleness episode) without needing an
    /// import-side hook to clear the setting.
    pub data_as_of: Option<DateTime<Utc>>,
}

impl StalenessSnooze {
    /// Whether this snooze suppresses a reminder for an institution whose
    /// newest data landed at `last_data_at`, evaluated at `now`.
    ///
    /// Suppressed only while BOTH hold:
    /// - the window is open (`now < until`), and
    /// - no data arrived since the dismiss (`last_data_at <= data_as_of`,
    ///   with 1s of tolerance so timestamp round-tripping through the
    ///   frontend's ISO-8601 serialization can't spuriously "un-snooze").
    ///
    /// A snooze without a parseable `data_as_of` degrades to time-only —
    /// still bounded by `until`, so a malformed entry can't mute forever.
    pub fn suppresses(&self, last_data_at: DateTime<Utc>, now: DateTime<Utc>) -> bool {
        if now >= self.until {
            return false;
        }
        match self.data_as_of {
            Some(data_as_of) => last_data_at <= data_as_of + Duration::seconds(1),
            None => true,
        }
    }
}

/// Parse the raw [`STALENESS_SNOOZE_SETTING_KEY`] value into a usable map.
/// Tolerant by design (the value is client-written JSON): non-object roots,
/// non-UUID keys, and entries without a parseable `until` are dropped —
/// a corrupt entry silently expires rather than muting forever.
pub fn snoozes_from_setting(value: Option<&serde_json::Value>) -> HashMap<Uuid, StalenessSnooze> {
    let mut out = HashMap::new();
    let Some(map) = value.and_then(|v| v.as_object()) else {
        return out;
    };
    for (key, entry) in map {
        let Ok(institution_id) = Uuid::parse_str(key) else {
            continue;
        };
        let parse_ts = |field: &str| {
            entry
                .get(field)
                .and_then(|v| v.as_str())
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(DateTime::<Utc>::from)
        };
        let Some(until) = parse_ts("until") else {
            continue;
        };
        out.insert(
            institution_id,
            StalenessSnooze {
                until,
                data_as_of: parse_ts("data_as_of"),
            },
        );
    }
    out
}

/// Parse the raw [`STALENESS_MUTE_SETTING_KEY`] value (JSON array of id
/// strings) into a set. Non-array roots / non-UUID entries are ignored.
pub fn muted_from_setting(value: Option<&serde_json::Value>) -> HashSet<Uuid> {
    value
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|v| v.as_str())
                .filter_map(|s| Uuid::parse_str(s).ok())
                .collect()
        })
        .unwrap_or_default()
}

/// An import-only institution whose newest data is older than the threshold.
#[derive(Debug, Clone)]
pub struct StaleInstitution {
    pub institution_id: Uuid,
    pub name: String,
    /// When data last arrived for ANY of its non-archived accounts.
    pub last_data_at: DateTime<Utc>,
    pub days_stale: i64,
}

/// Parse the user's threshold out of the raw `app_settings` JSON value.
///
/// Absent / non-numeric values fall back to [`DEFAULT_STALENESS_DAYS`];
/// numeric values are clamped to 1..=365 so a hostile or fat-fingered
/// setting (0, negative, 10⁹) can neither spam a notification every run
/// nor disable the feature by overflow (same clamp-at-the-boundary policy
/// as the FX history `?days=` window).
pub fn threshold_from_setting(value: Option<&serde_json::Value>) -> i64 {
    match value.and_then(|v| v.as_i64()) {
        Some(days) => days.clamp(1, 365),
        None => DEFAULT_STALENESS_DAYS,
    }
}

/// Every import-only (`integration_type = 'manual'`) institution of
/// `user_id` with the age of its freshest data, oldest first.
///
/// An institution's freshness is the MAX over its non-archived accounts of
/// GREATEST(account.updated_at, last transaction insert time): one freshly
/// imported account is enough to consider the institution current. This is
/// the same expression `/api/dashboard/overview` stamps onto each manual
/// account as `last_data_at`, so the banner and the bell can never disagree
/// about how old an institution is.
///
/// Unfiltered on purpose: the reminder writer wants the ones past the
/// threshold, the resolver wants the ones that dropped back under it, and
/// deriving both from one query keeps them from drifting.
pub async fn manual_institution_freshness(
    db: &PgPool,
    user_id: Uuid,
) -> Result<Vec<StaleInstitution>> {
    let rows = sqlx::query(
        r#"
        SELECT i.id, i.name,
               MAX(GREATEST(a.updated_at, tx.last_tx_at)) AS last_data_at
        FROM institutions i
        JOIN accounts a
          ON a.institution_id = i.id
         AND a.user_id = $1
         AND a.archived_at IS NULL
        LEFT JOIN LATERAL (
            SELECT MAX(t.created_at) AS last_tx_at
            FROM transactions t
            WHERE t.account_id = a.id AND t.user_id = $1
        ) tx ON TRUE
        WHERE i.user_id = $1 AND i.integration_type = 'manual'
        GROUP BY i.id, i.name
        ORDER BY MAX(GREATEST(a.updated_at, tx.last_tx_at)) ASC
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await?;

    let now = Utc::now();
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let last_data_at: DateTime<Utc> = row.try_get("last_data_at")?;
        out.push(StaleInstitution {
            institution_id: row.try_get("id")?,
            name: row.try_get("name")?,
            last_data_at,
            // Clock skew (a server timestamp slightly ahead of ours) reads
            // as 0 days, never negative — same guard as the frontend's
            // `accountDataAgeDays`.
            days_stale: (now - last_data_at).num_days().max(0),
        });
    }
    Ok(out)
}

/// The reminder's title. Embeds the institution name, and is the key the
/// dedup check and the resolver match rows on for reminders written before
/// `link_id` was populated — keep the two in one place so they can't drift.
pub fn staleness_title(institution: &str) -> String {
    format!("{institution} statement import overdue")
}

/// The reminder's body. Stored in English with the concrete number embedded,
/// matching the fx_alert precedent; a future notifications center can
/// re-render locale-aware copy off `kind`.
pub fn staleness_body(institution: &str, days_stale: i64) -> String {
    format!(
        "{institution} data is {days_stale} days old. \
         Import a fresh statement to keep balances accurate."
    )
}

/// One `app_settings` value for `user_id`, or None when unset. Small helper
/// so the sweep's three per-user reads (threshold / snoozes / mutes) stay
/// one obvious line each.
async fn fetch_setting(
    db: &PgPool,
    user_id: Uuid,
    key: &str,
) -> Result<Option<serde_json::Value>> {
    Ok(sqlx::query_scalar(
        "SELECT value FROM app_settings WHERE user_id = $1 AND key = $2",
    )
    .bind(user_id)
    .bind(key)
    .fetch_optional(db)
    .await?)
}

/// One user's three staleness preferences, read together because every
/// caller needs all three to answer the single question below.
struct StalenessPrefs {
    threshold_days: i64,
    snoozes: HashMap<Uuid, StalenessSnooze>,
    muted: HashSet<Uuid>,
}

impl StalenessPrefs {
    async fn load(db: &PgPool, user_id: Uuid) -> Result<Self> {
        Ok(Self {
            threshold_days: threshold_from_setting(
                fetch_setting(db, user_id, STALENESS_SETTING_KEY)
                    .await?
                    .as_ref(),
            ),
            snoozes: snoozes_from_setting(
                fetch_setting(db, user_id, STALENESS_SNOOZE_SETTING_KEY)
                    .await?
                    .as_ref(),
            ),
            muted: muted_from_setting(
                fetch_setting(db, user_id, STALENESS_MUTE_SETTING_KEY)
                    .await?
                    .as_ref(),
            ),
        })
    }

    /// Whether `inst` should have a reminder in the inbox right now.
    ///
    /// The single source of truth for both directions: the writer inserts
    /// when this is true, the resolver deletes when it is false. That is
    /// what keeps the bell in lockstep with the dashboard banner — a fresh
    /// import (data newer than the threshold) flips it to false, and so do
    /// a Settings mute and an active banner snooze.
    ///
    /// The age test is whole days (`days_stale >= threshold`) rather than an
    /// interval in SQL, so the boundary means exactly what the frontend
    /// banner's `age >= thresholdDays` means.
    fn should_notify(&self, inst: &StaleInstitution, now: DateTime<Utc>) -> bool {
        inst.days_stale >= self.threshold_days
            && !self.muted.contains(&inst.institution_id)
            && !self
                .snoozes
                .get(&inst.institution_id)
                .is_some_and(|s| s.suppresses(inst.last_data_at, now))
    }
}

/// Retire the caller's `import_stale` reminders that no longer describe
/// reality, and re-date the ones that still do. Returns rows deleted.
///
/// Called on every `GET /api/notifications`, because a stored reminder is a
/// claim about the present: after an import the dashboard banner recomputes
/// and disappears, but the bell row is frozen text that would otherwise keep
/// insisting the data is 45 days old for good.
///
/// For each manual institution exactly one of two things happens:
///
/// * [`StalenessPrefs::should_notify`] is false (fresh data landed, or the
///   user muted/snoozed it) → its reminder is **deleted**, which also fixes
///   the unread badge, and — because the writer's dedup only skips rows
///   newer than `last_data_at` — leaves the next real staleness episode free
///   to re-notify.
/// * it is still true → the reminder is **kept**, with its body refreshed to
///   today's day count (a reminder raised at 45 days says 52 a week later)
///   and `link_id` backfilled so a later rename still resolves it.
///
/// Rows we cannot attribute to a live institution (a deleted one, or a
/// pre-`link_id` row whose institution was renamed) are deliberately left
/// alone: deleting on "no match" would make any gap in the join look like a
/// resolution.
pub async fn resolve_stale_import_notifications(db: &PgPool, user_id: Uuid) -> Result<u64> {
    let prefs = StalenessPrefs::load(db, user_id).await?;
    let now = Utc::now();

    let (keep, resolved): (Vec<_>, Vec<_>) = manual_institution_freshness(db, user_id)
        .await?
        .into_iter()
        .partition(|inst| prefs.should_notify(inst, now));

    // Delete by id OR title: reminders written before this change carry a
    // NULL link_id and can only be matched on the title they embedded.
    let resolved_ids: Vec<String> = resolved
        .iter()
        .map(|i| i.institution_id.to_string())
        .collect();
    let resolved_titles: Vec<String> = resolved.iter().map(|i| staleness_title(&i.name)).collect();
    let kept_ids: Vec<String> = keep.iter().map(|i| i.institution_id.to_string()).collect();

    let deleted = sqlx::query(
        "DELETE FROM user_notifications \
         WHERE user_id = $1 AND kind = $2 \
           AND (link_id = ANY($3) OR title = ANY($4)) \
           AND (link_id IS NULL OR link_id <> ALL($5))",
    )
    .bind(user_id)
    .bind(STALENESS_NOTIFICATION_KIND)
    .bind(&resolved_ids)
    .bind(&resolved_titles)
    // Guard for two institutions sharing a name: a row that identifies
    // itself as one we're keeping is never collateral of the other's title.
    .bind(&kept_ids)
    .execute(db)
    .await?
    .rows_affected();

    for inst in keep {
        let title = staleness_title(&inst.name);
        let body = staleness_body(&inst.name, inst.days_stale);
        let link_id = inst.institution_id.to_string();
        sqlx::query(
            "UPDATE user_notifications \
                SET body = $4, link_kind = 'institution', link_id = $5 \
             WHERE user_id = $1 AND kind = $2 AND title = $3 \
               AND (body IS DISTINCT FROM $4 OR link_id IS DISTINCT FROM $5)",
        )
        .bind(user_id)
        .bind(STALENESS_NOTIFICATION_KIND)
        .bind(&title)
        .bind(&body)
        .bind(&link_id)
        .execute(db)
        .await?;
    }

    Ok(deleted)
}

/// Record a `user_notifications` row for every (user, manual institution)
/// pair whose data is past the user's threshold. Returns rows inserted.
///
/// ⚠ Deliberately NOT scoped to one user: the daily cron is a system-wide
/// sweep. Each SELECT inside IS user-scoped, and every inserted
/// notification carries the owning `user_id`.
///
/// Dedup is per staleness episode, not per run: skip the insert when a
/// notification of the same kind + title (title embeds the institution
/// name) already exists that is NEWER than the institution's last data.
/// A fresh import moves `last_data_at` past the old notification, so the
/// next time the institution goes stale a new reminder is allowed.
///
/// Snoozes and mutes are honored BEFORE the dedup check: a banner dismiss
/// (7-day snooze) or a Settings "Remind me" toggle-off must produce no
/// bell row at all, not merely a deduplicated one.
pub async fn record_staleness_notifications(db: &PgPool) -> Result<usize> {
    let user_rows = sqlx::query(
        "SELECT DISTINCT user_id FROM institutions \
         WHERE integration_type = 'manual' AND user_id IS NOT NULL",
    )
    .fetch_all(db)
    .await?;

    let mut recorded = 0usize;
    let now = Utc::now();
    for user_row in user_rows {
        let user_id: Uuid = user_row.try_get("user_id")?;

        let prefs = StalenessPrefs::load(db, user_id).await?;

        for inst in manual_institution_freshness(db, user_id).await? {
            // Under the threshold, permanently muted ("Remind me" off in
            // Settings), or actively snoozed (banner dismissed <7 days ago
            // with no data since): stay silent. An expired snooze — or one
            // whose data_as_of predates a fresh import — falls through and
            // notifies. The resolver applies the same test in reverse.
            if !prefs.should_notify(&inst, now) {
                continue;
            }
            let title = staleness_title(&inst.name);
            let already_notified: bool = sqlx::query_scalar(
                "SELECT EXISTS(
                     SELECT 1 FROM user_notifications
                     WHERE user_id = $1 AND kind = $2 AND title = $3
                       AND created_at > $4
                 )",
            )
            .bind(user_id)
            .bind(STALENESS_NOTIFICATION_KIND)
            .bind(&title)
            .bind(inst.last_data_at)
            .fetch_one(db)
            .await?;
            if already_notified {
                continue;
            }

            let body = staleness_body(&inst.name, inst.days_stale);
            // `link_id` records WHICH institution this is about, so the
            // resolver can retire the row even after a rename (the title
            // alone would no longer match).
            sqlx::query(
                "INSERT INTO user_notifications \
                     (user_id, kind, title, body, link_kind, link_id) \
                 VALUES ($1, $2, $3, $4, 'institution', $5)",
            )
            .bind(user_id)
            .bind(STALENESS_NOTIFICATION_KIND)
            .bind(&title)
            .bind(&body)
            .bind(inst.institution_id.to_string())
            .execute(db)
            .await?;
            recorded += 1;
        }
    }
    Ok(recorded)
}

#[cfg(test)]
mod tests {
    use super::{
        muted_from_setting, snoozes_from_setting, threshold_from_setting, StalenessSnooze,
        DEFAULT_STALENESS_DAYS,
    };
    use chrono::{Duration, TimeZone, Utc};
    use serde_json::json;
    use uuid::Uuid;

    #[test]
    fn absent_or_non_numeric_settings_fall_back_to_default() {
        assert_eq!(threshold_from_setting(None), DEFAULT_STALENESS_DAYS);
        assert_eq!(
            threshold_from_setting(Some(&json!("soon"))),
            DEFAULT_STALENESS_DAYS
        );
        assert_eq!(
            threshold_from_setting(Some(&json!(null))),
            DEFAULT_STALENESS_DAYS
        );
        // A fractional number has no i64 representation → default, not truncate.
        assert_eq!(
            threshold_from_setting(Some(&json!(12.5))),
            DEFAULT_STALENESS_DAYS
        );
    }

    #[test]
    fn hostile_values_are_clamped_not_honored() {
        assert_eq!(threshold_from_setting(Some(&json!(0))), 1);
        assert_eq!(threshold_from_setting(Some(&json!(-30))), 1);
        assert_eq!(threshold_from_setting(Some(&json!(1_000_000_000))), 365);
    }

    #[test]
    fn in_range_values_pass_through() {
        assert_eq!(threshold_from_setting(Some(&json!(30))), 30);
        assert_eq!(threshold_from_setting(Some(&json!(1))), 1);
        assert_eq!(threshold_from_setting(Some(&json!(365))), 365);
    }

    #[test]
    fn snooze_map_parses_and_drops_malformed_entries() {
        let id = Uuid::new_v4();
        let raw = json!({
            id.to_string(): {
                "until": "2026-08-01T00:00:00Z",
                "data_as_of": "2026-06-08T12:30:00Z",
            },
            // Not a UUID key → dropped.
            "CetesDirecto": { "until": "2026-08-01T00:00:00Z" },
            // No parseable until → dropped (can't mute forever by accident).
            Uuid::new_v4().to_string(): { "until": "whenever" },
        });
        let snoozes = snoozes_from_setting(Some(&raw));
        assert_eq!(snoozes.len(), 1, "only the well-formed entry survives");
        let s = snoozes.get(&id).expect("well-formed entry parsed");
        assert_eq!(s.until, Utc.with_ymd_and_hms(2026, 8, 1, 0, 0, 0).unwrap());
        assert_eq!(
            s.data_as_of,
            Some(Utc.with_ymd_and_hms(2026, 6, 8, 12, 30, 0).unwrap())
        );

        assert!(snoozes_from_setting(None).is_empty());
        assert!(snoozes_from_setting(Some(&json!("nope"))).is_empty());
        assert!(snoozes_from_setting(Some(&json!([1, 2]))).is_empty());
    }

    #[test]
    fn mute_list_parses_and_ignores_garbage() {
        let id = Uuid::new_v4();
        let muted = muted_from_setting(Some(&json!([id.to_string(), "not-a-uuid", 7])));
        assert_eq!(muted.len(), 1);
        assert!(muted.contains(&id));
        assert!(muted_from_setting(None).is_empty());
        assert!(muted_from_setting(Some(&json!({"a": 1}))).is_empty());
    }

    #[test]
    fn snooze_suppresses_only_inside_window_and_without_newer_data() {
        let now = Utc.with_ymd_and_hms(2026, 7, 24, 12, 0, 0).unwrap();
        let data_as_of = now - Duration::days(45);
        let snooze = StalenessSnooze {
            until: now + Duration::days(7),
            data_as_of: Some(data_as_of),
        };

        // Same data as at dismiss time → suppressed.
        assert!(snooze.suppresses(data_as_of, now));
        // Sub-second serialization drift must not defeat the snooze.
        assert!(snooze.suppresses(data_as_of + Duration::milliseconds(500), now));
        // A fresh import after the dismiss re-arms immediately.
        assert!(!snooze.suppresses(now - Duration::days(1), now));
        // Window expiry re-arms even with unchanged data.
        assert!(!snooze.suppresses(data_as_of, now + Duration::days(8)));

        // No data_as_of → time-bounded only.
        let time_only = StalenessSnooze {
            until: now + Duration::days(7),
            data_as_of: None,
        };
        assert!(time_only.suppresses(now, now));
        assert!(!time_only.suppresses(data_as_of, now + Duration::days(7)));
    }
}
