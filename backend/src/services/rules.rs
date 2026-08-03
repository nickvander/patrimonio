//! User rules engine — the SINGLE matcher implementation.
//!
//! Explicit, persisted, user-defined rules that categorize and/or rename
//! transactions. Consulted at **write time** on both insert paths
//! (statement-import confirm, Plaid sync) and applied retroactively only
//! through the previewed/confirmed apply endpoint (`api/rules.rs`). See
//! `work/RULES_ENGINE_DESIGN.md` and DEC-027.
//!
//! ## Why every caller goes through `apply_rules`
//!
//! Preview, retroactive apply, import confirm and Plaid sync all call the
//! same function. Matching is **never** duplicated in SQL: Postgres
//! `UPPER()`/`LIKE` and Rust `to_uppercase()`/`contains` disagree on
//! accent/case edges (Ñ, É, Á are routine in these descriptors), and any
//! divergence would break dry-run-vs-apply parity — which is the whole
//! safety story of this feature. The preview/apply handlers do a coarse
//! SQL prefilter (user + optional account/currency scope) and filter in
//! Rust.
//!
//! ## Precedence (design §2), highest first
//!
//! 1. Manual row edit — `user_* ` non-empty AND `*_source = 'manual'` (or
//!    legacy NULL). Absolute; no rule path may overwrite it, enforced by
//!    the SQL predicates below at *every* write site.
//! 2. User rules — first active match in `(priority, created_at, id)`
//!    order, **per action field**.
//! 3. Learn-from-edits (import path only) — `*_source = 'learned'`.
//! 4. Curated `categorize.rs` / Plaid PFC — the base `category` column.

use anyhow::Result;
use rust_decimal::Decimal;
use sha2::{Digest, Sha256};
use sqlx::{postgres::PgRow, PgPool, Row};
use uuid::Uuid;

use crate::services::categorize::merchant_key;

/// The matchers v1 ships. Mirrored by a CHECK constraint in
/// `2026080401_user_rules.sql`; validated here too so a bad value is a
/// friendly 400 rather than a 500 from the constraint.
pub const MATCH_TYPES: [&str; 4] = ["merchant_key", "contains", "starts_with", "exact"];

/// Scope axis: which sign of `amount` a rule is restricted to.
pub const DIRECTIONS: [&str; 2] = ["inflow", "outflow"];

/// A field is **manual-protected** iff its value is non-empty AND its
/// source says a human set it (`'manual'`, or NULL for rows that predate
/// the provenance columns). These fragments are the SQL twin of
/// [`is_protected`] and are spliced verbatim into every statement that
/// writes a rule result onto a pre-existing row, so "a human edit always
/// wins" is a predicate rather than a convention.
///
/// They reference the unqualified column names, so the statement must not
/// alias `transactions` (or must alias it as the default).
pub const CATEGORY_UNPROTECTED_SQL: &str =
    "NOT (user_category IS NOT NULL AND user_category <> '' \
     AND (user_category_source = 'manual' OR user_category_source IS NULL))";

/// See [`CATEGORY_UNPROTECTED_SQL`].
pub const DESCRIPTION_UNPROTECTED_SQL: &str =
    "NOT (user_description IS NOT NULL AND user_description <> '' \
     AND (user_description_source = 'manual' OR user_description_source IS NULL))";

/// Rust twin of [`CATEGORY_UNPROTECTED_SQL`] / [`DESCRIPTION_UNPROTECTED_SQL`],
/// used by the preview so the dry-run counts exactly what the apply will
/// write. Keep the two in lockstep — a divergence here is a silent
/// clobber of a human edit.
pub fn is_protected(value: Option<&str>, source: Option<&str>) -> bool {
    let has_value = value.map(|v| !v.is_empty()).unwrap_or(false);
    has_value && matches!(source, None | Some("manual"))
}

/// One row of `user_rules`.
#[derive(Debug, Clone)]
pub struct UserRule {
    pub id: Uuid,
    pub match_type: String,
    pub match_value: String,
    pub account_id: Option<Uuid>,
    pub currency: Option<String>,
    pub direction: Option<String>,
    pub amount_min: Option<Decimal>,
    pub amount_max: Option<Decimal>,
    pub set_category: Option<String>,
    pub set_description: Option<String>,
    pub priority: i32,
    pub active: bool,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

/// Everything a rule is allowed to look at on a transaction. Borrowed so
/// the per-row loops on the sync/import paths allocate nothing.
#[derive(Debug, Clone, Copy)]
pub struct RuleInput<'a> {
    pub description: &'a str,
    pub original_description: Option<&'a str>,
    pub merchant_name: Option<&'a str>,
    pub counterparty_name: Option<&'a str>,
    pub amount: Decimal,
    pub currency: &'a str,
    pub account_id: Uuid,
}

/// What the rule set decided for one row: `(value, rule id)` per action
/// field, or `None` when no active rule matched with that action.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RuleOutcome {
    pub category: Option<(String, Uuid)>,
    pub description: Option<(String, Uuid)>,
}

impl RuleOutcome {
    /// True when at least one action fired — i.e. the row matched a rule
    /// that had something to say about it.
    pub fn is_empty(&self) -> bool {
        self.category.is_none() && self.description.is_none()
    }
}

/// Fold the Latin-1 accents that actually occur in Mexican bank
/// descriptors down to their ASCII base letter. Deliberately a small,
/// explicit table rather than a Unicode-normalization dependency: the
/// input space is Spanish/English bank text, and an explicit table can't
/// surprise us with a locale-dependent transformation on the *sync* path.
fn fold_accent(c: char) -> char {
    match c {
        'Á' | 'À' | 'Â' | 'Ä' | 'Ã' | 'Å' => 'A',
        'É' | 'È' | 'Ê' | 'Ë' => 'E',
        'Í' | 'Ì' | 'Î' | 'Ï' => 'I',
        'Ó' | 'Ò' | 'Ô' | 'Ö' | 'Õ' => 'O',
        'Ú' | 'Ù' | 'Û' | 'Ü' => 'U',
        'Ñ' => 'N',
        'Ç' => 'C',
        'Ý' => 'Y',
        _ => c,
    }
}

/// Canonical comparison form: uppercase, accents folded, whitespace runs
/// collapsed to one space, trimmed. Both haystack and needle go through
/// it, so "Depósito  OXXO" matches a rule written as "deposito oxxo".
pub fn normalize(s: &str) -> String {
    let upper = s.to_uppercase();
    let mut out = String::with_capacity(upper.len());
    let mut pending_space = false;
    for c in upper.chars() {
        if c.is_whitespace() {
            // Only remember the gap once we've emitted something, and
            // never emit a trailing one — that trims both ends for free.
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(fold_accent(c));
    }
    out
}

/// The merchant-key basis for a row: `original_description ?? description`
/// — the same basis learn-from-edits uses on the import path, so a rule
/// and the learned map key off identical text.
pub fn merchant_key_basis<'a>(input: &RuleInput<'a>) -> &'a str {
    input.original_description.unwrap_or(input.description)
}

/// Does this rule match this row? Scope axes first (cheap), matcher last.
fn matches(rule: &UserRule, input: &RuleInput) -> bool {
    if !rule.active {
        return false;
    }
    if let Some(acc) = rule.account_id {
        if acc != input.account_id {
            return false;
        }
    }
    if let Some(cur) = rule.currency.as_deref() {
        if !cur.is_empty() && normalize(cur) != normalize(input.currency) {
            return false;
        }
    }
    if let Some(dir) = rule.direction.as_deref() {
        // Sign convention is the app's everywhere: negative = outflow,
        // positive = inflow. A zero-amount row matches neither direction.
        let ok = match dir {
            "inflow" => input.amount > Decimal::ZERO,
            "outflow" => input.amount < Decimal::ZERO,
            _ => false,
        };
        if !ok {
            return false;
        }
    }
    // Amount ranges compare the NATIVE magnitude (design §8 q6): a range
    // without a currency scope compares MXN and USD magnitudes raw, and
    // the UI nudges the user to set a currency when they set a range.
    let magnitude = input.amount.abs();
    if let Some(min) = rule.amount_min {
        if magnitude < min {
            return false;
        }
    }
    if let Some(max) = rule.amount_max {
        if magnitude > max {
            return false;
        }
    }

    match rule.match_type.as_str() {
        "merchant_key" => {
            // Reuse categorize::merchant_key on BOTH sides rather than
            // reimplementing the normalizer. Running it over the stored
            // match_value is idempotent for an already-derived key (the UI
            // stores `derived_merchant_key`) and forgiving when the user
            // pasted a raw descriptor instead.
            let row_key = normalize(&merchant_key(merchant_key_basis(input)));
            let rule_key = normalize(&merchant_key(&rule.match_value));
            // merchant_key returns "" for generic rows ("PAGO TARJETA DE
            // DEBITO"); an empty key must never match everything.
            !rule_key.is_empty() && row_key == rule_key
        }
        kind @ ("contains" | "starts_with" | "exact") => {
            let needle = normalize(&rule.match_value);
            if needle.is_empty() {
                return false;
            }
            [
                Some(input.description),
                input.original_description,
                input.merchant_name,
                input.counterparty_name,
            ]
            .into_iter()
            .flatten()
            .any(|hay| {
                let hay = normalize(hay);
                match kind {
                    "contains" => hay.contains(&needle),
                    "starts_with" => hay.starts_with(&needle),
                    _ => hay == needle,
                }
            })
        }
        // Unknown matcher (a future match_type read by an older binary):
        // match nothing. Never fall back to a looser matcher — that would
        // apply a rule the user never wrote.
        _ => false,
    }
}

/// Evaluate an ordered rule set against one row.
///
/// **First-match-wins per action field**: the first matching rule that
/// carries a `set_category` decides the category, and the first matching
/// rule that carries a `set_description` decides the description — so a
/// rename-only rule never shadows a categorize rule below it. `rules` must
/// already be in `(priority ASC, created_at ASC, id ASC)` order — that's
/// what [`load_rules`] returns.
pub fn apply_rules(rules: &[UserRule], input: &RuleInput) -> RuleOutcome {
    let mut out = RuleOutcome::default();
    for rule in rules {
        if out.category.is_some() && out.description.is_some() {
            break;
        }
        if !matches(rule, input) {
            continue;
        }
        if out.category.is_none() {
            if let Some(cat) = rule.set_category.as_ref().filter(|v| !v.is_empty()) {
                out.category = Some((cat.clone(), rule.id));
            }
        }
        if out.description.is_none() {
            if let Some(desc) = rule.set_description.as_ref().filter(|v| !v.is_empty()) {
                out.description = Some((desc.clone(), rule.id));
            }
        }
    }
    out
}

/// Materialise a `user_rules` row. Shared by [`load_rules`] and the API
/// module so the column→field mapping exists exactly once.
pub fn rule_from_row(row: &PgRow) -> UserRule {
    UserRule {
        id: row.get("id"),
        match_type: row.get("match_type"),
        match_value: row.get("match_value"),
        account_id: row.try_get("account_id").ok().flatten(),
        currency: row.try_get("currency").ok().flatten(),
        direction: row.try_get("direction").ok().flatten(),
        amount_min: row.try_get("amount_min").ok().flatten(),
        amount_max: row.try_get("amount_max").ok().flatten(),
        set_category: row.try_get("set_category").ok().flatten(),
        set_description: row.try_get("set_description").ok().flatten(),
        priority: row.get("priority"),
        active: row.get("active"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

/// The columns every rule read selects, in one place so the row mapper
/// can't drift from the queries.
pub const RULE_COLUMNS: &str = "id, match_type, match_value, account_id, currency, direction, \
     amount_min, amount_max, set_category, set_description, priority, active, created_at, updated_at";

/// A user's ACTIVE rules in evaluation order. Both write paths call this
/// once per batch (per import confirm / per institution sync), never per
/// row.
pub async fn load_rules(db: &PgPool, user_id: Uuid) -> Result<Vec<UserRule>> {
    let rows = sqlx::query(&format!(
        "SELECT {RULE_COLUMNS} FROM user_rules \
         WHERE user_id = $1 AND active \
         ORDER BY priority ASC, created_at ASC, id ASC"
    ))
    .bind(user_id)
    .fetch_all(db)
    .await?;
    Ok(rows.iter().map(rule_from_row).collect())
}

/// A stable hash of a rule's *definition* — matcher + scope + actions.
///
/// Deliberately excludes id, priority, active and timestamps: a preview
/// token minted before the rule was created must stay valid for the
/// identical just-created rule, and reordering rules doesn't change what
/// this rule would do to the previewed rows. The match value is hashed in
/// its [`normalize`]d form, so a cosmetic whitespace/case edit that can't
/// change which rows match doesn't invalidate a pending preview; the
/// action values are hashed verbatim because they're written to the row
/// byte-for-byte.
pub fn fingerprint(rule: &UserRule) -> String {
    let mut h = Sha256::new();
    // \u{1} can't occur in any of these fields, so the concatenation is
    // unambiguous (no "ab|c" vs "a|bc" collisions).
    let sep = "\u{1}";
    for part in [
        rule.match_type.trim().to_ascii_lowercase(),
        normalize(&rule.match_value),
        rule.account_id.map(|a| a.to_string()).unwrap_or_default(),
        rule.currency.as_deref().map(normalize).unwrap_or_default(),
        rule.direction
            .as_deref()
            .map(|d| d.trim().to_ascii_lowercase())
            .unwrap_or_default(),
        rule.amount_min.map(|d| d.to_string()).unwrap_or_default(),
        rule.amount_max.map(|d| d.to_string()).unwrap_or_default(),
        rule.set_category.clone().unwrap_or_default(),
        rule.set_description.clone().unwrap_or_default(),
    ] {
        h.update(part.as_bytes());
        h.update(sep.as_bytes());
    }
    format!("{:x}", h.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn rule(match_type: &str, match_value: &str) -> UserRule {
        UserRule {
            id: Uuid::new_v4(),
            match_type: match_type.to_string(),
            match_value: match_value.to_string(),
            account_id: None,
            currency: None,
            direction: None,
            amount_min: None,
            amount_max: None,
            set_category: Some("Dining".to_string()),
            set_description: None,
            priority: 0,
            active: true,
            created_at: chrono::Utc::now(),
            updated_at: chrono::Utc::now(),
        }
    }

    fn input<'a>(description: &'a str, amount: Decimal, account: Uuid) -> RuleInput<'a> {
        RuleInput {
            description,
            original_description: None,
            merchant_name: None,
            counterparty_name: None,
            amount,
            currency: "MXN",
            account_id: account,
        }
    }

    fn fired(rules: &[UserRule], i: &RuleInput) -> bool {
        !apply_rules(rules, i).is_empty()
    }

    #[test]
    fn contains_matches_case_and_accent_insensitively() {
        let r = rule("contains", "deposito");
        let acc = Uuid::new_v4();
        assert!(fired(
            std::slice::from_ref(&r),
            &input("DEPÓSITO OXXO SUC 12", dec!(-100), acc)
        ));
        assert!(fired(
            std::slice::from_ref(&r),
            &input("depósito oxxo", dec!(-100), acc)
        ));
        assert!(!fired(
            std::slice::from_ref(&r),
            &input("RETIRO CAJERO", dec!(-100), acc)
        ));
    }

    #[test]
    fn n_tilde_descriptors_match_their_ascii_spelling() {
        // The reason matching lives in Rust and not in SQL: Ñ/ñ/N must all
        // be the same letter to a rule the user typed on a phone keyboard.
        let r = rule("contains", "espana");
        let acc = Uuid::new_v4();
        assert!(fired(
            std::slice::from_ref(&r),
            &input("COMPRA ESPAÑA MADRID", dec!(-50), acc)
        ));
    }

    #[test]
    fn starts_with_and_exact_are_anchored() {
        let acc = Uuid::new_v4();
        let sw = rule("starts_with", "spei");
        assert!(fired(
            std::slice::from_ref(&sw),
            &input("SPEI ENVIADO A JUAN", dec!(-10), acc)
        ));
        assert!(!fired(
            std::slice::from_ref(&sw),
            &input("PAGO SPEI RECIBIDO", dec!(10), acc)
        ));

        let ex = rule("exact", "netflix");
        assert!(fired(
            std::slice::from_ref(&ex),
            &input("Netflix", dec!(-10), acc)
        ));
        assert!(!fired(
            std::slice::from_ref(&ex),
            &input("Netflix MX", dec!(-10), acc)
        ));
    }

    #[test]
    fn matchers_see_merchant_and_counterparty_fields() {
        let acc = Uuid::new_v4();
        let r = rule("contains", "starbucks");
        let mut i = input("MISCELLANEOUS DEBIT", dec!(-80), acc);
        i.counterparty_name = Some("Starbucks");
        assert!(fired(std::slice::from_ref(&r), &i));

        let mut i2 = input("MISCELLANEOUS DEBIT", dec!(-80), acc);
        i2.merchant_name = Some("STARBUCKS REFORMA");
        assert!(fired(std::slice::from_ref(&r), &i2));
    }

    #[test]
    fn merchant_key_matcher_agrees_with_categorize_merchant_key() {
        let acc = Uuid::new_v4();
        // categorize::merchant_key("COMPRA STARBUCKS REFORMA REF 9981")
        // == "STARBUCKS REFORMA" — the rule stores that derived key.
        let r = rule("merchant_key", "STARBUCKS REFORMA");
        assert!(fired(
            std::slice::from_ref(&r),
            &input("COMPRA STARBUCKS REFORMA REF 9981", dec!(-95), acc)
        ));
        // A different merchant with the same leading noise must not match.
        assert!(!fired(
            std::slice::from_ref(&r),
            &input("COMPRA SEVEN ELEVEN REF 12", dec!(-95), acc)
        ));
    }

    #[test]
    fn merchant_key_matcher_uses_original_description_when_present() {
        let acc = Uuid::new_v4();
        let r = rule("merchant_key", "STARBUCKS REFORMA");
        let mut i = input("Card purchase", dec!(-95), acc);
        i.original_description = Some("COMPRA STARBUCKS REFORMA REF 9981");
        assert!(fired(std::slice::from_ref(&r), &i));
    }

    #[test]
    fn merchant_key_never_matches_when_the_rule_key_is_generic() {
        // merchant_key("PAGO TARJETA DE DEBITO") == "" — an empty key must
        // not become a match-everything rule.
        let acc = Uuid::new_v4();
        let r = rule("merchant_key", "PAGO TARJETA DE DEBITO");
        assert!(!fired(
            std::slice::from_ref(&r),
            &input("PAGO TARJETA DE DEBITO", dec!(-95), acc)
        ));
    }

    #[test]
    fn scope_axes_narrow_the_match() {
        let acc = Uuid::new_v4();
        let other = Uuid::new_v4();

        let mut by_account = rule("contains", "oxxo");
        by_account.account_id = Some(acc);
        assert!(fired(
            std::slice::from_ref(&by_account),
            &input("OXXO", dec!(-10), acc)
        ));
        assert!(!fired(
            std::slice::from_ref(&by_account),
            &input("OXXO", dec!(-10), other)
        ));

        let mut by_currency = rule("contains", "oxxo");
        by_currency.currency = Some("USD".into());
        assert!(!fired(
            std::slice::from_ref(&by_currency),
            &input("OXXO", dec!(-10), acc)
        ));

        let mut by_direction = rule("contains", "oxxo");
        by_direction.direction = Some("inflow".into());
        assert!(!fired(
            std::slice::from_ref(&by_direction),
            &input("OXXO", dec!(-10), acc)
        ));
        assert!(fired(
            std::slice::from_ref(&by_direction),
            &input("OXXO", dec!(10), acc)
        ));
        // Zero belongs to neither direction.
        assert!(!fired(
            std::slice::from_ref(&by_direction),
            &input("OXXO", dec!(0), acc)
        ));
    }

    #[test]
    fn amount_range_compares_native_magnitude() {
        let acc = Uuid::new_v4();
        let mut r = rule("contains", "oxxo");
        r.amount_min = Some(dec!(100));
        r.amount_max = Some(dec!(500));
        // -250 → magnitude 250, inside the range even though the stored
        // amount is negative.
        assert!(fired(
            std::slice::from_ref(&r),
            &input("OXXO", dec!(-250), acc)
        ));
        assert!(!fired(
            std::slice::from_ref(&r),
            &input("OXXO", dec!(-50), acc)
        ));
        assert!(!fired(
            std::slice::from_ref(&r),
            &input("OXXO", dec!(-501), acc)
        ));
        // Boundaries are inclusive.
        assert!(fired(
            std::slice::from_ref(&r),
            &input("OXXO", dec!(-100), acc)
        ));
        assert!(fired(
            std::slice::from_ref(&r),
            &input("OXXO", dec!(-500), acc)
        ));
    }

    #[test]
    fn inactive_rules_are_ignored() {
        let acc = Uuid::new_v4();
        let mut r = rule("contains", "oxxo");
        r.active = false;
        assert!(!fired(
            std::slice::from_ref(&r),
            &input("OXXO", dec!(-10), acc)
        ));
    }

    #[test]
    fn first_match_wins_per_action_field() {
        let acc = Uuid::new_v4();
        // A rename-only rule sits first; it must NOT shadow the
        // categorize rule below it.
        let mut rename = rule("contains", "oxxo");
        rename.set_category = None;
        rename.set_description = Some("OXXO".into());
        rename.priority = 0;

        let mut categorize = rule("contains", "oxxo");
        categorize.set_category = Some("Groceries".into());
        categorize.priority = 10;

        // A later categorize rule must lose to the earlier one.
        let mut shadowed = rule("contains", "oxxo");
        shadowed.set_category = Some("Dining".into());
        shadowed.priority = 20;

        let out = apply_rules(
            &[rename.clone(), categorize.clone(), shadowed],
            &input("OXXO SUC 5", dec!(-30), acc),
        );
        assert_eq!(
            out.category,
            Some(("Groceries".to_string(), categorize.id)),
            "first matching rule WITH a category wins"
        );
        assert_eq!(
            out.description,
            Some(("OXXO".to_string(), rename.id)),
            "rename-only rule still supplies the description"
        );
    }

    #[test]
    fn non_matching_rules_leave_the_outcome_empty() {
        let acc = Uuid::new_v4();
        let r = rule("contains", "walmart");
        let out = apply_rules(std::slice::from_ref(&r), &input("OXXO", dec!(-30), acc));
        assert!(out.is_empty());
    }

    #[test]
    fn protection_predicate_matches_the_sql_twin() {
        // Legacy rows (NULL source) and explicit manual edits are
        // protected; rule/learned values are not.
        assert!(is_protected(Some("Dining"), None));
        assert!(is_protected(Some("Dining"), Some("manual")));
        assert!(!is_protected(Some("Dining"), Some("rule")));
        assert!(!is_protected(Some("Dining"), Some("learned")));
        // An empty/absent value is never protected.
        assert!(!is_protected(Some(""), Some("manual")));
        assert!(!is_protected(None, Some("manual")));
    }

    #[test]
    fn fingerprint_ignores_id_priority_and_cosmetic_whitespace() {
        let a = rule("contains", "OXXO GAS");
        let mut b = a.clone();
        b.id = Uuid::new_v4();
        b.priority = 99;
        b.active = false;
        b.match_value = "  oxxo   gas ".to_string();
        assert_eq!(
            fingerprint(&a),
            fingerprint(&b),
            "a token minted before create must stay valid for the identical created rule"
        );

        let mut c = a.clone();
        c.set_category = Some("Transportation".into());
        assert_ne!(
            fingerprint(&a),
            fingerprint(&c),
            "changing what the rule WRITES must invalidate the preview"
        );

        let mut d = a.clone();
        d.amount_min = Some(dec!(10));
        assert_ne!(
            fingerprint(&a),
            fingerprint(&d),
            "changing scope must invalidate the preview"
        );
    }
}
