use anyhow::Result;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, Row};

#[derive(Debug, Serialize, Deserialize)]
pub struct TaxBracket {
    #[serde(with = "rust_decimal::serde::float")]
    pub rate: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub cutoff: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub base_tax: Decimal,
}

/// Year-level tax estimate.
///
/// CANONICAL UNITS: every money field is **USD** unless its name ends in
/// `_mxn`. Income rows stored in MXN are converted per-row at the USD→MXN
/// rate in effect on each transaction's date (see `USD_MXN_ROW_RATE_SQL`),
/// so the USD fields feed the US brackets and the `_mxn` fields feed the
/// SAT tarifa — the raw mixed-currency amounts are never summed together.
/// The frontend multiplies the USD fields by a single USD→display
/// `conversionFactor`; the `_mxn` fields are additive extras for exports
/// and reconciliation.
#[derive(Debug, Serialize, Deserialize)]
pub struct TaxEstimation {
    /// Income-categorized inflows for the year, in **USD** (per-row FX).
    #[serde(with = "rust_decimal::serde::float")]
    pub ordinary_income: Decimal,
    /// Same income rows summed in **MXN** (per-row FX) — the base the
    /// Mexican ISR tarifa is applied to.
    #[serde(with = "rust_decimal::serde::float")]
    pub ordinary_income_mxn: Decimal,
    /// Taxable realized capital gains (short + long), in **USD**.
    #[serde(with = "rust_decimal::serde::float")]
    pub capital_gains: Decimal,
    /// Short-term realized gains (held <= 1 year) in **USD** — taxed as
    /// ordinary income.
    #[serde(with = "rust_decimal::serde::float")]
    pub short_term_gains: Decimal,
    /// Long-term realized gains (held > 1 year) in **USD** — preferential
    /// LTCG rates.
    #[serde(with = "rust_decimal::serde::float")]
    pub long_term_gains: Decimal,
    /// Realized gains inside tax-advantaged wrappers (401k/IRA/HSA/...), in
    /// **USD**. NOT part of `capital_gains` or any liability figure —
    /// surfaced separately so excluded activity is visible rather than
    /// silently dropped.
    #[serde(with = "rust_decimal::serde::float")]
    pub tax_advantaged_gains: Decimal,
    /// True when the gains came from precise lot-disposal records rather than
    /// the blended cost-basis fallback.
    pub gains_from_lots: bool,
    /// `ordinary_income + capital_gains`, in **USD**.
    #[serde(with = "rust_decimal::serde::float")]
    pub total_taxable: Decimal,
    /// `ordinary_income_mxn + capital_gains × usd_mxn_rate_used`, in **MXN**
    /// — the figure actually fed to the ISR tarifa.
    #[serde(with = "rust_decimal::serde::float")]
    pub total_taxable_mxn: Decimal,
    /// Estimated US (IRS) liability, in **USD**.
    #[serde(with = "rust_decimal::serde::float")]
    pub estimated_liability_us: Decimal,
    /// Estimated MX (SAT) liability, converted to **USD** at
    /// `usd_mxn_rate_used` so the response stays single-currency for the
    /// frontend's `conversionFactor`. The native tarifa output is
    /// `estimated_liability_mx_mxn`.
    #[serde(with = "rust_decimal::serde::float")]
    pub estimated_liability_mx: Decimal,
    /// Estimated MX (SAT) liability in **MXN** — the raw tarifa output.
    #[serde(with = "rust_decimal::serde::float")]
    pub estimated_liability_mx_mxn: Decimal,
    /// USD→MXN rate used for the year-level conversions above (gains→MXN and
    /// MXN liability→USD): the nearest stored rate on-or-before Dec 31 of the
    /// tax year, else the latest stored rate, else the 20.0 ballpark.
    #[serde(with = "rust_decimal::serde::float")]
    pub usd_mxn_rate_used: Decimal,
    /// `estimated_liability_us / total_taxable` (both USD); dimensionless.
    #[serde(with = "rust_decimal::serde::float")]
    pub effective_rate_us: Decimal,
    /// `estimated_liability_mx / total_taxable` (both USD); dimensionless.
    #[serde(with = "rust_decimal::serde::float")]
    pub effective_rate_mx: Decimal,
}

/// Account subtypes whose internal trades are not taxable events — the
/// 401k/IRA/HSA-style wrappers. Values are matched case-insensitively against
/// `accounts.account_type`, which migration `2026060801_normalize_account_type`
/// (and the create-account handler since then) keeps lowercase; the Plaid
/// subtype vocabulary is the source of these spellings ("roth" = Roth IRA,
/// "roth 401k" = designated Roth).
///
/// Disposals in these accounts are excluded from taxable short/long-term gains
/// and reported separately (`TaxEstimation::tax_advantaged_gains`, plus their
/// own labeled CSV section).
pub const TAX_ADVANTAGED_ACCOUNT_TYPES: &[&str] = &[
    "401k",
    "403b",
    "457b",
    "ira",
    "roth",
    "roth 401k",
    "hsa",
    "529",
    "pension",
];

/// True when an `accounts.account_type` value is a tax-advantaged wrapper.
/// Case-insensitive; `None`/unknown types count as taxable (conservative:
/// gains stay in the estimate rather than vanishing from it).
pub fn is_tax_advantaged_account_type(account_type: Option<&str>) -> bool {
    account_type
        .map(|t| {
            let t = t.trim().to_lowercase();
            TAX_ADVANTAGED_ACCOUNT_TYPES.contains(&t.as_str())
        })
        .unwrap_or(false)
}

/// The advantaged-subtype list as a bindable `text[]` parameter for
/// `LOWER(account_type) = ANY($n)` predicates.
fn tax_advantaged_types_param() -> Vec<String> {
    TAX_ADVANTAGED_ACCOUNT_TYPES
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// SQL predicate for "this transaction is income", matching the taxonomy the
/// writers actually store: Plaid sync persists the PFC primary `'INCOME'` with
/// `category_detailed` like `'INCOME_WAGES'` (sync.rs), and the statement
/// categorizer emits `'INCOME'` (categorize.rs). Matching is case-insensitive.
///
/// A non-empty `user_category` override wins in BOTH directions: overriding to
/// 'INCOME'/'Income' opts a row in, overriding to anything else opts an
/// auto-categorized income row out. (`\_` keeps the underscore literal in
/// LIKE so e.g. 'INCOMES…' can't sneak in.)
const INCOME_PREDICATE_SQL: &str = r#"(
    CASE
        WHEN NULLIF(user_category, '') IS NOT NULL
            THEN UPPER(user_category) = 'INCOME'
        ELSE UPPER(category) = 'INCOME'
             OR UPPER(category_detailed) LIKE 'INCOME\_%'
    END
)"#;

/// SQL scalar: the USD→MXN rate in effect on a transaction row's date.
/// Requires the enclosing query to alias `transactions` as `t`; meant to be
/// wrapped in `CROSS JOIN LATERAL (SELECT {..} AS rate) fx`.
///
/// Lookup rule (mirrors sync.rs `lookup_usd_fx_rate`, the same rule the lot
/// FX columns were stamped with):
///   1. the latest stored `exchange_rates` row dated on-or-before `t.date`
///      (`recorded_at < t.date + 1 day` so same-day timestamps count);
///   2. else the latest stored USD→MXN rate of any date (fresh FX history
///      that starts after old imported statements);
///   3. else a hard 20.0 ballpark — wrong-ish magnitude beats the old
///      behavior of summing raw MXN and USD amounts together, which was off
///      ~18x by construction. Zero/negative stored rates are skipped so a
///      bad row can never divide-by-zero a sum into NULL.
const USD_MXN_ROW_RATE_SQL: &str = r#"COALESCE(
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0
        AND recorded_at < (t.date + INTERVAL '1 day')
      ORDER BY recorded_at DESC LIMIT 1),
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0
      ORDER BY recorded_at DESC LIMIT 1),
    20.0
)"#;

/// SQL expressions converting `t.amount` to USD / MXN using `fx.rate` (the
/// LATERAL-projected `USD_MXN_ROW_RATE_SQL`). Currencies other than MXN are
/// treated as USD-equivalent (fx = 1) — the same "trust the native amount"
/// stance sync.rs takes for unknown currencies.
const AMOUNT_USD_SQL: &str =
    "(CASE WHEN UPPER(t.currency) = 'MXN' THEN t.amount / fx.rate ELSE t.amount END)";
const AMOUNT_MXN_SQL: &str =
    "(CASE WHEN UPPER(t.currency) = 'MXN' THEN t.amount ELSE t.amount * fx.rate END)";

pub struct TaxService;

impl TaxService {
    // Basic 2026 Single Filer Brackets (Approximation for demonstration)
    fn get_us_brackets_single() -> Vec<TaxBracket> {
        vec![
            TaxBracket { rate: dec!(0.10), cutoff: dec!(11600), base_tax: dec!(0) },
            TaxBracket { rate: dec!(0.12), cutoff: dec!(47150), base_tax: dec!(1160) },
            TaxBracket { rate: dec!(0.22), cutoff: dec!(100525), base_tax: dec!(5426) },
            TaxBracket { rate: dec!(0.24), cutoff: dec!(191950), base_tax: dec!(17168.5) },
            TaxBracket { rate: dec!(0.32), cutoff: dec!(243725), base_tax: dec!(39110.5) },
            TaxBracket { rate: dec!(0.35), cutoff: dec!(609350), base_tax: dec!(55678.5) },
            TaxBracket { rate: dec!(0.37), cutoff: Decimal::MAX, base_tax: dec!(183647.25) },
        ]
    }

    // Basic 2026 Married Filing Jointly Brackets (Approximation)
    fn get_us_brackets_married() -> Vec<TaxBracket> {
        vec![
            TaxBracket { rate: dec!(0.10), cutoff: dec!(23200), base_tax: dec!(0) },
            TaxBracket { rate: dec!(0.12), cutoff: dec!(94300), base_tax: dec!(2320) },
            TaxBracket { rate: dec!(0.22), cutoff: dec!(201050), base_tax: dec!(10852) },
            TaxBracket { rate: dec!(0.24), cutoff: dec!(383900), base_tax: dec!(34337) },
            TaxBracket { rate: dec!(0.32), cutoff: dec!(487450), base_tax: dec!(78221) },
            TaxBracket { rate: dec!(0.35), cutoff: dec!(731200), base_tax: dec!(111357) },
            TaxBracket { rate: dec!(0.37), cutoff: Decimal::MAX, base_tax: dec!(196669.5) },
        ]
    }

    // Basic 2026 Head of Household Brackets (Approximation)
    fn get_us_brackets_hoh() -> Vec<TaxBracket> {
        vec![
            TaxBracket { rate: dec!(0.10), cutoff: dec!(16550), base_tax: dec!(0) },
            TaxBracket { rate: dec!(0.12), cutoff: dec!(63100), base_tax: dec!(1655) },
            TaxBracket { rate: dec!(0.22), cutoff: dec!(100500), base_tax: dec!(7241) },
            TaxBracket { rate: dec!(0.24), cutoff: dec!(191950), base_tax: dec!(15469) },
            TaxBracket { rate: dec!(0.32), cutoff: dec!(243700), base_tax: dec!(37417) },
            TaxBracket { rate: dec!(0.35), cutoff: dec!(609350), base_tax: dec!(53977) },
            TaxBracket { rate: dec!(0.37), cutoff: Decimal::MAX, base_tax: dec!(181954.5) },
        ]
    }

    // Mexico 2026 ISR Mensual elevated to Annual
    fn get_mx_brackets() -> Vec<TaxBracket> {
        vec![
            TaxBracket { rate: dec!(0.0192), cutoff: dec!(11122.20), base_tax: dec!(0) },
            TaxBracket { rate: dec!(0.0640), cutoff: dec!(94354.08), base_tax: dec!(213.60) },
            TaxBracket { rate: dec!(0.1088), cutoff: dec!(165842.16), base_tax: dec!(5540.88) },
            TaxBracket { rate: dec!(0.1600), cutoff: dec!(192809.52), base_tax: dec!(13316.52) },
            TaxBracket { rate: dec!(0.2136), cutoff: dec!(230867.76), base_tax: dec!(17631.24) },
            TaxBracket { rate: dec!(0.2352), cutoff: dec!(465660.12), base_tax: dec!(25760.64) },
            TaxBracket { rate: dec!(0.3000), cutoff: dec!(921098.52), base_tax: dec!(80979.60) },
            TaxBracket { rate: dec!(0.3200), cutoff: dec!(1758509.64), base_tax: dec!(217611.12) },
            TaxBracket { rate: dec!(0.3400), cutoff: dec!(5861732.16), base_tax: dec!(485582.76) },
            TaxBracket { rate: dec!(0.3500), cutoff: Decimal::MAX, base_tax: dec!(1880678.40) },
        ]
    }

    pub fn calculate_us_tax(income: Decimal, status: &str) -> Decimal {
        let brackets = if status == "Married" {
            Self::get_us_brackets_married()
        } else if status == "Head of Household" {
            Self::get_us_brackets_hoh()
        } else {
            Self::get_us_brackets_single()
        };

        if income <= dec!(0) {
            return dec!(0);
        }

        let mut previous_cutoff = dec!(0);
        for bracket in brackets {
            if income <= bracket.cutoff {
                let amount_in_bracket = income - previous_cutoff;
                return bracket.base_tax + (amount_in_bracket * bracket.rate);
            }
            previous_cutoff = bracket.cutoff;
        }
        dec!(0)
    }

    /// Long-term capital-gains tax (US, 2026 approx). LT gains stack ON TOP of
    /// ordinary taxable income to find the 0% / 15% / 20% bands. Only positive
    /// gains are taxed (loss handling is left to the ordinary-income side).
    pub fn calculate_us_ltcg(gain: Decimal, ordinary_taxable: Decimal, status: &str) -> Decimal {
        if gain <= dec!(0) {
            return dec!(0);
        }
        // (top of 0% band, top of 15% band) by filing status.
        let (t0, t15) = match status {
            "Married" => (dec!(96700), dec!(600050)),
            "Head of Household" => (dec!(64750), dec!(566700)),
            _ => (dec!(48350), dec!(533400)),
        };
        let start = ordinary_taxable.max(dec!(0));
        let end = start + gain;
        let band = |lo: Decimal, hi: Decimal| -> Decimal {
            (end.min(hi) - start.max(lo)).max(dec!(0))
        };
        let in15 = band(t0, t15);
        let in20 = band(t15, Decimal::MAX);
        in15 * dec!(0.15) + in20 * dec!(0.20)
    }

    pub fn calculate_mx_tax(income: Decimal) -> Decimal {
         if income <= dec!(0) {
            return dec!(0);
        }

        let brackets = Self::get_mx_brackets();
        let mut previous_cutoff = dec!(0);
        for bracket in brackets {
            if income <= bracket.cutoff {
                let amount_in_bracket = income - previous_cutoff;
                return bracket.base_tax + (amount_in_bracket * bracket.rate);
            }
            previous_cutoff = bracket.cutoff;
        }
        dec!(0)
    }

    pub async fn calculate_yearly_tax(
        db: &PgPool,
        year: i32,
        status: &str,
        user_id: uuid::Uuid,
    ) -> Result<TaxEstimation> {
        let start_date = chrono::NaiveDate::from_ymd_opt(year, 1, 1).unwrap();
        let end_date = chrono::NaiveDate::from_ymd_opt(year, 12, 31).unwrap();

        // 1. Ordinary income: sum of income-categorized inflows — scoped to
        //    user, matching the stored taxonomy (see INCOME_PREDICATE_SQL).
        //    Each row is converted at ITS OWN date's USD→MXN rate (see
        //    USD_MXN_ROW_RATE_SQL for the lookup + fallback rule) into two
        //    bases: a USD total that feeds the US brackets and an MXN total
        //    that feeds the SAT tarifa. Raw mixed-currency amounts are never
        //    added together.
        let income_sql = format!(
            r#"
            SELECT
                COALESCE(SUM({AMOUNT_USD_SQL}), 0) AS income_usd,
                COALESCE(SUM({AMOUNT_MXN_SQL}), 0) AS income_mxn
            FROM transactions t
            CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
            WHERE t.date >= $1 AND t.date <= $2
            AND t.amount > 0
            AND {INCOME_PREDICATE_SQL}
            AND t.user_id = $3
            "#
        );
        let income_row = sqlx::query(&income_sql)
        .bind(start_date)
        .bind(end_date)
        .bind(user_id)
        .fetch_one(db)
        .await?;

        let ordinary_income: Decimal = income_row.try_get("income_usd").unwrap_or_default();
        let ordinary_income_mxn: Decimal = income_row.try_get("income_mxn").unwrap_or_default();

        // 2. Realized capital gains from PRECISE lot disposals (actual P&L
        //    with holding periods), split short- vs long-term. Disposals
        //    inside tax-advantaged wrappers (401k/IRA/HSA/... — see
        //    TAX_ADVANTAGED_ACCOUNT_TYPES) are NOT taxable events: they're
        //    kept out of both buckets and reported separately. No disposals
        //    means no realized gains — the old "Investment Sale" blended
        //    fallback matched a category no writer ever produced and is gone.
        let disp = sqlx::query(
            r#"
            SELECT
                COALESCE(SUM(CASE WHEN NOT adv.is_adv
                                   AND l.acquired_at IS NOT NULL
                                   AND (d.sell_date - l.acquired_at) <= 365
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS short_term,
                -- Long-term: held > 1 year, OR holding period unknown (the
                -- source lot was deleted) — most brokerage lots are long-term,
                -- so this is the conservative default.
                COALESCE(SUM(CASE WHEN NOT adv.is_adv
                                   AND (l.acquired_at IS NULL
                                        OR (d.sell_date - l.acquired_at) > 365)
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS long_term,
                COALESCE(SUM(CASE WHEN adv.is_adv
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS tax_advantaged,
                COUNT(*) AS n
            FROM lot_disposals d
            LEFT JOIN holding_lots l ON l.id = d.lot_id
            JOIN accounts a ON a.id = d.account_id
            CROSS JOIN LATERAL (
                SELECT LOWER(COALESCE(a.account_type, '')) = ANY($3) AS is_adv
            ) adv
            WHERE d.user_id = $1
              AND EXTRACT(YEAR FROM d.sell_date)::int = $2
            "#,
        )
        .bind(user_id)
        .bind(year)
        .bind(tax_advantaged_types_param())
        .fetch_one(db)
        .await?;

        let disposal_count: i64 = disp.try_get("n").unwrap_or(0);
        let gains_from_lots = disposal_count > 0;

        let short_term_gains: Decimal = disp.try_get("short_term").unwrap_or_default();
        let long_term_gains: Decimal = disp.try_get("long_term").unwrap_or_default();
        let tax_advantaged_gains: Decimal = disp.try_get("tax_advantaged").unwrap_or_default();

        let capital_gains = short_term_gains + long_term_gains;

        // US: short-term gains stack onto ordinary income (ordinary brackets);
        // long-term gains get the preferential LTCG rates on top of that.
        let ordinary_taxable = ordinary_income + short_term_gains;
        let estimated_liability_us = Self::calculate_us_tax(ordinary_taxable, status)
            + Self::calculate_us_ltcg(long_term_gains, ordinary_taxable, status);

        // MX: no preferential split here — everything flows through the ISR
        // brackets (a deliberate simplification). The tarifa is applied to an
        // MXN base: per-row-converted income plus the USD capital gains
        // converted at the year rate; the resulting MXN liability is also
        // reported back-converted to USD at that same rate so every non-`_mxn`
        // field in the response is USD.
        let total_taxable = ordinary_income + capital_gains;
        let usd_mxn_rate_used = Self::usd_mxn_year_rate(db, year).await?;
        let total_taxable_mxn = ordinary_income_mxn + capital_gains * usd_mxn_rate_used;
        let estimated_liability_mx_mxn = Self::calculate_mx_tax(total_taxable_mxn);
        let estimated_liability_mx = if usd_mxn_rate_used > dec!(0) {
            estimated_liability_mx_mxn / usd_mxn_rate_used
        } else {
            dec!(0)
        };

        let effective_rate_us = if total_taxable > dec!(0) { estimated_liability_us / total_taxable } else { dec!(0) };
        let effective_rate_mx = if total_taxable > dec!(0) { estimated_liability_mx / total_taxable } else { dec!(0) };

        Ok(TaxEstimation {
            ordinary_income,
            ordinary_income_mxn,
            capital_gains,
            short_term_gains,
            long_term_gains,
            tax_advantaged_gains,
            gains_from_lots,
            total_taxable,
            total_taxable_mxn,
            estimated_liability_us,
            estimated_liability_mx,
            estimated_liability_mx_mxn,
            usd_mxn_rate_used,
            effective_rate_us,
            effective_rate_mx,
        })
    }

    /// The USD→MXN rate used for year-level conversions (capital gains →
    /// MXN for the tarifa, and the MXN liability → USD for the response):
    /// the nearest stored rate on-or-before Dec 31 of the tax year, falling
    /// back to the latest stored rate, then to the 20.0 ballpark — the same
    /// chain as the per-row rule, anchored at year-end.
    async fn usd_mxn_year_rate(db: &PgPool, year: i32) -> Result<Decimal> {
        let year_end = chrono::NaiveDate::from_ymd_opt(year, 12, 31).unwrap();
        let row = sqlx::query(
            r#"
            SELECT COALESCE(
                (SELECT rate FROM exchange_rates
                  WHERE base_currency = 'USD' AND target_currency = 'MXN'
                    AND rate > 0
                    AND recorded_at < ($1::date + INTERVAL '1 day')
                  ORDER BY recorded_at DESC LIMIT 1),
                (SELECT rate FROM exchange_rates
                  WHERE base_currency = 'USD' AND target_currency = 'MXN'
                    AND rate > 0
                  ORDER BY recorded_at DESC LIMIT 1),
                20.0
            ) AS rate
            "#,
        )
        .bind(year_end)
        .fetch_one(db)
        .await?;
        Ok(row.try_get("rate").unwrap_or(dec!(20)))
    }

    pub async fn get_taxable_transactions(
        db: &PgPool,
        year: i32,
        user_id: uuid::Uuid,
    ) -> Result<Vec<TaxableTransaction>> {
        let start_date = chrono::NaiveDate::from_ymd_opt(year, 1, 1).unwrap();
        let end_date = chrono::NaiveDate::from_ymd_opt(year, 12, 31).unwrap();

        // Income events only — realized capital gains live in lot_disposals
        // (see get_lot_disposals), not in a transaction category. Each row
        // carries `amount_usd`, converted at the SAME per-date rate the
        // summary uses, so the visible rows sum exactly to the headline
        // `ordinary_income`.
        let tx_sql = format!(
            r#"
            SELECT t.*, {AMOUNT_USD_SQL} AS amount_usd
            FROM transactions t
            CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
            WHERE t.date >= $1 AND t.date <= $2
            AND t.amount > 0
            AND {INCOME_PREDICATE_SQL}
            AND t.user_id = $3
            ORDER BY t.date DESC
            "#
        );
        let rows = sqlx::query_as::<_, TaxableTransaction>(&tx_sql)
        .bind(start_date)
        .bind(end_date)
        .bind(user_id)
        .fetch_all(db)
        .await?;

        Ok(rows)
    }

    /// Per-disposal realized capital gains for a year — the Form 8949-style
    /// detail behind `short_term_gains` / `long_term_gains`. USD proceeds and
    /// cost basis are derived from the stored per-unit prices and FX rates the
    /// same way `/dashboard/realized-gains` does (fx is native-units-per-USD, so
    /// divide native amounts by it). Long-term = held > 365 days; null when the
    /// source lot's acquisition date is no longer on file.
    pub async fn get_lot_disposals(
        db: &PgPool,
        year: i32,
        user_id: uuid::Uuid,
    ) -> Result<Vec<TaxDisposal>> {
        let rows = sqlx::query(
            r#"
            SELECT h.symbol, h.name,
                   TO_CHAR(l.acquired_at, 'YYYY-MM-DD') AS acquired_date,
                   TO_CHAR(d.sell_date, 'YYYY-MM-DD') AS sell_date,
                   d.qty_sold, d.sell_price_per_unit, d.sell_fx_rate,
                   d.cost_per_unit, d.cost_fx_rate, d.realized_pnl_usd,
                   (d.sell_date - l.acquired_at) AS holding_days,
                   a.account_type
            FROM lot_disposals d
            JOIN holdings h ON h.id = d.holding_id
            JOIN accounts a ON a.id = d.account_id
            LEFT JOIN holding_lots l ON l.id = d.lot_id
            WHERE d.user_id = $1
              AND EXTRACT(YEAR FROM d.sell_date)::int = $2
            ORDER BY d.sell_date ASC
            "#,
        )
        .bind(user_id)
        .bind(year)
        .fetch_all(db)
        .await?;

        let dec = |r: &sqlx::postgres::PgRow, col: &str| -> Decimal {
            r.try_get::<Decimal, _>(col).unwrap_or_default()
        };

        Ok(rows
            .iter()
            .map(|r| {
                let qty = dec(r, "qty_sold");
                let sell_px = dec(r, "sell_price_per_unit");
                let sell_fx = dec(r, "sell_fx_rate");
                let cost_px = dec(r, "cost_per_unit");
                let cost_fx = dec(r, "cost_fx_rate");
                let proceeds_usd = if sell_fx > Decimal::ZERO {
                    qty * sell_px / sell_fx
                } else {
                    qty * sell_px
                };
                let cost_usd = if cost_fx > Decimal::ZERO {
                    qty * cost_px / cost_fx
                } else {
                    qty * cost_px
                };
                let holding_days: Option<i32> = r.try_get("holding_days").ok();
                let account_type: Option<String> =
                    r.try_get::<Option<String>, _>("account_type").unwrap_or(None);
                let tax_advantaged = is_tax_advantaged_account_type(account_type.as_deref());
                TaxDisposal {
                    symbol: r.try_get("symbol").unwrap_or_default(),
                    name: r.try_get("name").unwrap_or_default(),
                    acquired_date: r.try_get("acquired_date").ok(),
                    sell_date: r.try_get("sell_date").unwrap_or_default(),
                    qty_sold: qty,
                    proceeds_usd,
                    cost_usd,
                    gain_usd: dec(r, "realized_pnl_usd"),
                    long_term: holding_days.map(|d| d > 365),
                    account_type,
                    tax_advantaged,
                }
            })
            .collect())
    }
}

/// An income transaction in the taxable-events list. JSON-wise this is the
/// plain transaction shape (flattened, so existing consumers keep working)
/// plus `amount_usd`: the native `amount` converted to **USD** at the row's
/// own date rate (`USD_MXN_ROW_RATE_SQL`). Summing `amount_usd` over the
/// year's rows reproduces `TaxEstimation::ordinary_income` exactly.
#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct TaxableTransaction {
    #[sqlx(flatten)]
    #[serde(flatten)]
    pub tx: crate::models::transaction::Transaction,
    /// Native `amount` in USD at the transaction date's stored USD/MXN rate.
    #[serde(with = "rust_decimal::serde::float")]
    pub amount_usd: Decimal,
}

/// One realized capital-gains disposal row for the tax exports.
#[derive(Debug, Serialize, Deserialize)]
pub struct TaxDisposal {
    pub symbol: String,
    pub name: String,
    /// Acquisition date (YYYY-MM-DD), or None when the source lot is gone.
    pub acquired_date: Option<String>,
    pub sell_date: String,
    pub qty_sold: Decimal,
    pub proceeds_usd: Decimal,
    pub cost_usd: Decimal,
    pub gain_usd: Decimal,
    /// True = long-term (held > 365d), false = short-term, None = unknown term.
    pub long_term: Option<bool>,
    /// `accounts.account_type` of the account the disposal happened in
    /// (lowercase per migration 2026060801).
    pub account_type: Option<String>,
    /// True when the disposal happened inside a tax-advantaged wrapper
    /// (TAX_ADVANTAGED_ACCOUNT_TYPES) — excluded from taxable gains and from
    /// the 8949 CSV section, reported in its own section instead.
    pub tax_advantaged: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ltcg_zero_bracket_when_income_low() {
        // Single, no other income, $40k LT gain — entirely in the 0% band.
        assert_eq!(
            TaxService::calculate_us_ltcg(dec!(40000), dec!(0), "Single"),
            dec!(0)
        );
    }

    #[test]
    fn ltcg_stacks_on_ordinary_income() {
        // Single, $40k ordinary taxable, $20k LT gain: stacked 40k→60k. The 0%
        // band tops out at 48,350, so 8,350 is free and 11,650 is taxed at 15%.
        let tax = TaxService::calculate_us_ltcg(dec!(20000), dec!(40000), "Single");
        assert_eq!(tax, dec!(1747.50));
    }

    #[test]
    fn ltcg_twenty_percent_top_band() {
        // High earner: a $10k gain entirely above the 15% ceiling → 20%.
        let tax = TaxService::calculate_us_ltcg(dec!(10000), dec!(600000), "Single");
        assert_eq!(tax, dec!(2000));
    }

    #[test]
    fn tax_advantaged_type_matching_is_case_insensitive_and_none_safe() {
        assert!(is_tax_advantaged_account_type(Some("401k")));
        assert!(is_tax_advantaged_account_type(Some("HSA")));
        assert!(is_tax_advantaged_account_type(Some("Roth 401k")));
        assert!(is_tax_advantaged_account_type(Some(" ira ")));
        assert!(!is_tax_advantaged_account_type(Some("brokerage")));
        assert!(!is_tax_advantaged_account_type(Some("depository")));
        assert!(!is_tax_advantaged_account_type(None));
    }

    #[test]
    fn ltcg_ignores_losses() {
        assert_eq!(
            TaxService::calculate_us_ltcg(dec!(-5000), dec!(50000), "Single"),
            dec!(0)
        );
    }
}
