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
    ///
    /// Decomposition (T6): `ordinary_income = wage_income + dividend_income
    /// + interest_income` — three disjoint buckets split on
    /// `category_detailed`, so nothing is double-counted. The bracket math
    /// still runs over this total; the parts are reporting lines.
    #[serde(with = "rust_decimal::serde::float")]
    pub ordinary_income: Decimal,
    /// Cash dividends (income rows with `category_detailed =
    /// 'INCOME_DIVIDENDS'`, the rows the Plaid investment sync persists), in
    /// **USD** (same per-row FX rule as `ordinary_income`). Part of — never
    /// in addition to — `ordinary_income`. Qualified-vs-ordinary dividend
    /// classification is deliberately not modeled yet (deferred in the
    /// backlog); everything here is taxed at ordinary rates.
    #[serde(with = "rust_decimal::serde::float")]
    pub dividend_income: Decimal,
    /// Brokerage/bank interest (income rows with `category_detailed =
    /// 'INCOME_INTEREST_EARNED'`), in **USD**. Part of `ordinary_income`.
    #[serde(with = "rust_decimal::serde::float")]
    pub interest_income: Decimal,
    /// The residual bucket: `ordinary_income − dividend_income −
    /// interest_income`, in **USD** — wages, salary, and any other income
    /// row that isn't dividends or interest.
    #[serde(with = "rust_decimal::serde::float")]
    pub wage_income: Decimal,
    /// Same income rows summed in **MXN** (per-row FX) — the base the
    /// Mexican ISR tarifa is applied to.
    #[serde(with = "rust_decimal::serde::float")]
    pub ordinary_income_mxn: Decimal,
    /// Taxable realized capital gains (short + long), in **USD**.
    #[serde(with = "rust_decimal::serde::float")]
    pub capital_gains: Decimal,
    /// Net short-term realized gains/losses in **USD**: sold within one
    /// calendar year of acquisition, plus unknown-acquisition disposals
    /// (counted short-term — the conservative, higher-rate bucket). Raw
    /// bucket sum (may be negative) BEFORE the ST/LT netting that feeds the
    /// liability.
    #[serde(with = "rust_decimal::serde::float")]
    pub short_term_gains: Decimal,
    /// Net long-term realized gains/losses in **USD**: sold more than one
    /// calendar year after acquisition. Raw bucket sum (may be negative)
    /// BEFORE netting.
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
    /// The bracket year whose constant tables were actually applied. Equal to
    /// the requested tax year when a table exists for it; otherwise the
    /// nearest populated year (see [`SUPPORTED_BRACKET_YEARS`]).
    pub bracket_year_used: i32,
    /// Mirrors [`TAX_CONSTANTS_VERIFIED`]. While `false`, every bracket /
    /// deduction / tarifa constant behind this estimate is UNVERIFIED and the
    /// UI must badge the figures as pending human verification.
    pub constants_verified: bool,
    /// US standard deduction subtracted before the ordinary brackets and the
    /// LTCG stacking start, in **USD** (by filing status and bracket year;
    /// unverified like the rest of the tables).
    #[serde(with = "rust_decimal::serde::float")]
    pub standard_deduction_used: Decimal,
    /// Net capital loss left over after the capped ordinary-income offset, in
    /// **USD** (>= 0). Under the modeled-but-UNVERIFIED IRS rules this would
    /// carry forward to next year's netting; the app does not yet apply it to
    /// any other year — it is reported so the number doesn't silently vanish.
    /// The ST/LT character split of the carryforward is not modeled.
    #[serde(with = "rust_decimal::serde::float")]
    pub capital_loss_carryforward: Decimal,
    /// Realized losses (in **USD**, reported as a signed sum so it is <= 0)
    /// DISALLOWED for the year by the wash-sale rule (T12): taxable-account
    /// loss disposals with a same-`holding_id` buy inside the ±30-day window
    /// (see [`WASH_SALE_WINDOW_DAYS`]). These are already excluded from
    /// `short_term_gains` / `long_term_gains` and therefore from the netting
    /// and the liability — this field reports the magnitude that was removed
    /// so the exclusion is visible rather than silent. Wash-sale scope is on
    /// the human-verification list (assumptions item 5).
    #[serde(with = "rust_decimal::serde::float")]
    pub wash_sale_disallowed_loss: Decimal,
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

/// Wash-sale window (T12). A realized LOSS on `holding_id` at sale date D is a
/// wash sale if a BUY of the SAME `holding_id` exists in `holding_lots` with
/// `acquired_at` inside the 61-day window `[D-30, D+30]` (inclusive). The same
/// window backs the forward-looking harvest guard in T11, with D = the
/// contemplated sale date (today).
///
/// ⚠ SIMPLIFICATIONS ON THE HUMAN-VERIFICATION LIST (work/ux/tax_planning_tasks.md,
/// assumptions item 5):
///   - "Same `holding_id`" is a proxy for the IRS "substantially identical
///     securities" test. It will miss e.g. two share classes / two tickers of
///     the same fund, and will not catch options or replacement securities in
///     a different holding row.
///   - The window is scanned across ALL of the user's accounts (cross-account
///     scope), with no special handling of IRA/Roth replacement-purchase rules.
///   - A buy is any `holding_lots` row in the window regardless of its `qty`
///     (including FIFO-depletion marker rows, which are harmless here because
///     they carry the same `acquired_at`/`holding_id` as a real buy would).
const WASH_SALE_WINDOW_DAYS: i64 = 30;

// =====================================================================
// Year-keyed tax constant tables (T4)
// =====================================================================

/// ⚠ Single gate for ALL tax constants in this module. Set to `true` ONLY
/// after a tax professional has verified every table below against its named
/// primary source (the IRS Revenue Procedure for each US year, SAT Anexo 8
/// RMF for each MX tarifa) — see "Assumptions a tax professional must verify"
/// in work/ux/tax_planning_tasks.md. While `false`, every `/tax/summary`
/// response carries `"constants_verified": false` so the UI badges the
/// estimates as pending verification.
pub const TAX_CONSTANTS_VERIFIED: bool = false;

/// Bracket years with populated tables. A requested year without a table
/// resolves to the NEAREST populated year (ties go to the later year) and the
/// response reports the year actually used via `bracket_year_used`.
pub const SUPPORTED_BRACKET_YEARS: &[i32] = &[2025, 2026];

/// One US progressive bracket: `rate` applies to taxable income above the
/// previous bracket's `upto`, up to this bracket's `upto`.
///
/// There is deliberately NO stored cumulative-tax ("base tax") column: the
/// old hand-maintained `base_tax` values were a redundant second copy of the
/// rate/cutoff information that had already drifted across vintages in this
/// file. The cumulative tax is derived at calculation time instead, so the
/// table cannot be internally inconsistent.
#[derive(Debug, Clone, Copy)]
pub struct ProgressiveBracket {
    pub rate: Decimal,
    pub upto: Decimal,
}

/// US constants for one filing status in one bracket year.
#[derive(Debug, Clone)]
pub struct UsStatusTables {
    pub ordinary: Vec<ProgressiveBracket>,
    /// Standard deduction — subtracted from gross ordinary income before the
    /// ordinary brackets AND before the LTCG stacking start (itemizing is not
    /// modeled).
    pub standard_deduction: Decimal,
    /// Top of the 0% LTCG band, on the taxable-income axis.
    pub ltcg_0_top: Decimal,
    /// Top of the 15% LTCG band; gain stacked above it is taxed at 20%.
    pub ltcg_15_top: Decimal,
}

/// All tax constants for one bracket year. Built by [`TaxYearTables::for_year`].
pub struct TaxYearTables {
    /// The year these tables claim to describe (may differ from the requested
    /// tax year — see [`SUPPORTED_BRACKET_YEARS`]).
    pub bracket_year: i32,
    pub us_single: UsStatusTables,
    pub us_married: UsStatusTables,
    pub us_hoh: UsStatusTables,
    /// MX annual ISR tarifa: `cutoff` = límite superior, `base_tax` = cuota
    /// fija (kept as published rather than derived, because SAT's published
    /// cuotas embed their own rounding).
    pub mx_tarifa: Vec<TaxBracket>,
    /// Cap on the net capital loss deductible against ordinary income in one
    /// year (modeled after IRC §1211(b)'s $3,000; the $1,500
    /// married-filing-separately variant is not modeled because the app has
    /// no MFS filing status).
    /// ⚠ UNVERIFIED — requires human verification (assumptions item 4).
    pub capital_loss_ordinary_offset_cap: Decimal,
}

fn pb(rate: Decimal, upto: Decimal) -> ProgressiveBracket {
    ProgressiveBracket { rate, upto }
}

/// MX annual ISR tarifa used for BOTH 2025 and 2026 until verified figures
/// are supplied.
///
/// ⚠ UNVERIFIED — requires human verification against SAT Anexo 8 RMF for
/// each supported year. These are the annual tarifa values believed to be in
/// force since 2023; the 2026 tarifa may have been inflation-adjusted and
/// MUST be replaced with the published Anexo 8 figures on verification.
///
/// Note: this REPLACES the tarifa previously hardcoded in this file (first
/// cutoff 11,122.20 @ 1.92%, labeled "Mensual elevated to Annual"), which
/// could not be matched to any published SAT tarifa, monthly or annual.
fn mx_tarifa_2023_vintage() -> Vec<TaxBracket> {
    vec![
        TaxBracket { rate: dec!(0.0192), cutoff: dec!(8952.49), base_tax: dec!(0) },
        TaxBracket { rate: dec!(0.0640), cutoff: dec!(75984.55), base_tax: dec!(171.88) },
        TaxBracket { rate: dec!(0.1088), cutoff: dec!(133536.07), base_tax: dec!(4461.94) },
        TaxBracket { rate: dec!(0.1600), cutoff: dec!(155229.80), base_tax: dec!(10723.55) },
        TaxBracket { rate: dec!(0.2136), cutoff: dec!(185852.57), base_tax: dec!(14194.54) },
        TaxBracket { rate: dec!(0.2352), cutoff: dec!(374837.88), base_tax: dec!(20737.57) },
        TaxBracket { rate: dec!(0.3000), cutoff: dec!(590795.99), base_tax: dec!(65182.13) },
        TaxBracket { rate: dec!(0.3200), cutoff: dec!(1127926.84), base_tax: dec!(129969.55) },
        TaxBracket { rate: dec!(0.3400), cutoff: dec!(3898140.12), base_tax: dec!(301851.45) },
        TaxBracket { rate: dec!(0.3500), cutoff: Decimal::MAX, base_tax: dec!(1243723.97) },
    ]
}

impl TaxYearTables {
    /// Tables for `year`, falling back to the nearest populated bracket year
    /// (ties to the later year). `bracket_year` records what was used.
    pub fn for_year(year: i32) -> TaxYearTables {
        let nearest = SUPPORTED_BRACKET_YEARS
            .iter()
            .copied()
            .min_by_key(|y| ((y - year).abs(), std::cmp::Reverse(*y)))
            .expect("SUPPORTED_BRACKET_YEARS is non-empty");
        match nearest {
            2025 => Self::tables_2025(),
            _ => Self::tables_2026(),
        }
    }

    /// US 2025 + MX tarifa.
    ///
    /// ⚠ UNVERIFIED — requires human verification against IRS Rev. Proc.
    /// 2024-40 (ordinary brackets, LTCG bands) as amended by the 2025 OBBBA
    /// for the standard deduction, and SAT Anexo 8 RMF 2025 for the tarifa.
    /// Do not present these figures as authoritative until
    /// [`TAX_CONSTANTS_VERIFIED`] is flipped by a human.
    fn tables_2025() -> TaxYearTables {
        TaxYearTables {
            bracket_year: 2025,
            us_single: UsStatusTables {
                ordinary: vec![
                    pb(dec!(0.10), dec!(11925)),
                    pb(dec!(0.12), dec!(48475)),
                    pb(dec!(0.22), dec!(103350)),
                    pb(dec!(0.24), dec!(197300)),
                    pb(dec!(0.32), dec!(250525)),
                    pb(dec!(0.35), dec!(626350)),
                    pb(dec!(0.37), Decimal::MAX),
                ],
                standard_deduction: dec!(15750),
                ltcg_0_top: dec!(48350),
                ltcg_15_top: dec!(533400),
            },
            us_married: UsStatusTables {
                ordinary: vec![
                    pb(dec!(0.10), dec!(23850)),
                    pb(dec!(0.12), dec!(96950)),
                    pb(dec!(0.22), dec!(206700)),
                    pb(dec!(0.24), dec!(394600)),
                    pb(dec!(0.32), dec!(501050)),
                    pb(dec!(0.35), dec!(751600)),
                    pb(dec!(0.37), Decimal::MAX),
                ],
                standard_deduction: dec!(31500),
                ltcg_0_top: dec!(96700),
                ltcg_15_top: dec!(600050),
            },
            us_hoh: UsStatusTables {
                ordinary: vec![
                    pb(dec!(0.10), dec!(17000)),
                    pb(dec!(0.12), dec!(64850)),
                    pb(dec!(0.22), dec!(103350)),
                    pb(dec!(0.24), dec!(197300)),
                    pb(dec!(0.32), dec!(250500)),
                    pb(dec!(0.35), dec!(626350)),
                    pb(dec!(0.37), Decimal::MAX),
                ],
                standard_deduction: dec!(23625),
                ltcg_0_top: dec!(64750),
                ltcg_15_top: dec!(566700),
            },
            mx_tarifa: mx_tarifa_2023_vintage(),
            capital_loss_ordinary_offset_cap: dec!(3000),
        }
    }

    /// US 2026 + MX tarifa.
    ///
    /// ⚠ UNVERIFIED — requires human verification against IRS Rev. Proc.
    /// 2025-32 (ordinary brackets, LTCG bands, standard deduction, incl. any
    /// post-OBBBA changes) and SAT Anexo 8 RMF 2026 for the tarifa. The old
    /// in-file brackets that the UI claimed were "2026" were actually
    /// 2024-vintage ordinary brackets next to 2025-vintage LTCG bands; they
    /// were replaced, not kept. Do not present these figures as authoritative
    /// until [`TAX_CONSTANTS_VERIFIED`] is flipped by a human.
    fn tables_2026() -> TaxYearTables {
        TaxYearTables {
            bracket_year: 2026,
            us_single: UsStatusTables {
                ordinary: vec![
                    pb(dec!(0.10), dec!(12400)),
                    pb(dec!(0.12), dec!(50400)),
                    pb(dec!(0.22), dec!(105700)),
                    pb(dec!(0.24), dec!(201775)),
                    pb(dec!(0.32), dec!(256225)),
                    pb(dec!(0.35), dec!(640600)),
                    pb(dec!(0.37), Decimal::MAX),
                ],
                standard_deduction: dec!(16100),
                ltcg_0_top: dec!(49450),
                ltcg_15_top: dec!(545500),
            },
            us_married: UsStatusTables {
                ordinary: vec![
                    pb(dec!(0.10), dec!(24800)),
                    pb(dec!(0.12), dec!(100800)),
                    pb(dec!(0.22), dec!(211400)),
                    pb(dec!(0.24), dec!(403550)),
                    pb(dec!(0.32), dec!(512450)),
                    pb(dec!(0.35), dec!(768700)),
                    pb(dec!(0.37), Decimal::MAX),
                ],
                standard_deduction: dec!(32200),
                ltcg_0_top: dec!(98900),
                ltcg_15_top: dec!(613700),
            },
            us_hoh: UsStatusTables {
                ordinary: vec![
                    pb(dec!(0.10), dec!(17700)),
                    pb(dec!(0.12), dec!(67450)),
                    pb(dec!(0.22), dec!(105700)),
                    pb(dec!(0.24), dec!(201775)),
                    pb(dec!(0.32), dec!(256200)),
                    pb(dec!(0.35), dec!(640600)),
                    pb(dec!(0.37), Decimal::MAX),
                ],
                standard_deduction: dec!(24150),
                ltcg_0_top: dec!(66200),
                ltcg_15_top: dec!(579600),
            },
            mx_tarifa: mx_tarifa_2023_vintage(),
            capital_loss_ordinary_offset_cap: dec!(3000),
        }
    }

    /// The per-status US tables. Unknown statuses fall back to Single (the
    /// same default the API layer applies).
    pub fn us_status(&self, status: &str) -> &UsStatusTables {
        match status {
            "Married" => &self.us_married,
            "Head of Household" => &self.us_hoh,
            _ => &self.us_single,
        }
    }
}

/// Result of ST/LT capital netting — see [`TaxService::net_capital_buckets`].
#[derive(Debug, PartialEq, Eq)]
pub struct CapitalNetting {
    /// Net short-term gain surviving the netting (>= 0); taxed at ordinary
    /// rates on top of ordinary income.
    pub st_taxable_gain: Decimal,
    /// Net long-term gain surviving the netting (>= 0); taxed at the LTCG
    /// band rates, stacked on taxable ordinary income.
    pub lt_taxable_gain: Decimal,
    /// Net capital loss applied against ordinary income this year (>= 0,
    /// capped at the year table's `capital_loss_ordinary_offset_cap`).
    pub ordinary_loss_offset: Decimal,
    /// Net capital loss left over after the capped offset (>= 0) — the
    /// implied carryforward.
    pub carryforward: Decimal,
}

/// The pieces of the US liability computation that callers/tests need.
#[derive(Debug, PartialEq, Eq)]
pub struct UsLiability {
    pub liability: Decimal,
    /// Ordinary income after net ST gains, the capital-loss offset, and the
    /// standard deduction: `max(0, ordinary + net ST − offset − deduction)`.
    /// This is also where LT gains start stacking for the LTCG bands.
    pub taxable_ordinary: Decimal,
    pub standard_deduction_used: Decimal,
    pub capital_loss_carryforward: Decimal,
}

pub struct TaxService;

impl TaxService {
    /// Progressive US ordinary-bracket tax over already-deducted taxable
    /// income. The cumulative tax is accumulated bracket by bracket — no
    /// stored base-tax column to drift out of sync with the cutoffs.
    pub fn calculate_us_ordinary_tax(taxable: Decimal, t: &UsStatusTables) -> Decimal {
        if taxable <= dec!(0) {
            return dec!(0);
        }
        let mut tax = dec!(0);
        let mut prev = dec!(0);
        for b in &t.ordinary {
            tax += (taxable.min(b.upto) - prev).max(dec!(0)) * b.rate;
            if taxable <= b.upto {
                break;
            }
            prev = b.upto;
        }
        tax
    }

    /// Long-term capital-gains tax. LT gains stack ON TOP of taxable ordinary
    /// income (i.e. AFTER the standard deduction) to find the 0% / 15% / 20%
    /// bands. Only positive gains are taxed — losses must be routed through
    /// [`Self::net_capital_buckets`] first, never passed here.
    pub fn calculate_us_ltcg(
        gain: Decimal,
        taxable_ordinary: Decimal,
        t: &UsStatusTables,
    ) -> Decimal {
        if gain <= dec!(0) {
            return dec!(0);
        }
        let start = taxable_ordinary.max(dec!(0));
        let end = start + gain;
        let band = |lo: Decimal, hi: Decimal| -> Decimal {
            (end.min(hi) - start.max(lo)).max(dec!(0))
        };
        let in15 = band(t.ltcg_0_top, t.ltcg_15_top);
        let in20 = band(t.ltcg_15_top, Decimal::MAX);
        in15 * dec!(0.15) + in20 * dec!(0.20)
    }

    /// MX ISR over the given tarifa (cuota fija + marginal rate above the
    /// previous límite superior).
    pub fn calculate_mx_tax(income: Decimal, tarifa: &[TaxBracket]) -> Decimal {
        if income <= dec!(0) {
            return dec!(0);
        }
        let mut previous_cutoff = dec!(0);
        for bracket in tarifa {
            if income <= bracket.cutoff {
                let amount_in_bracket = income - previous_cutoff;
                return bracket.base_tax + (amount_in_bracket * bracket.rate);
            }
            previous_cutoff = bracket.cutoff;
        }
        dec!(0)
    }

    /// ST/LT capital netting, modeled after the standard IRS ordering:
    /// gains and losses net WITHIN each bucket first (the inputs here are
    /// already the per-bucket nets); a net loss in one bucket then offsets the
    /// other bucket's net gain; any remaining net capital loss offsets
    /// ordinary income up to `cap` per year, and the excess is the implied
    /// carryforward.
    ///
    /// ⚠ The ordering rules themselves are on the human-verification list
    /// (work/ux/tax_planning_tasks.md, assumptions item 4) — as is the cap
    /// constant. The carryforward's ST/LT character split is not modeled;
    /// only its total is reported.
    pub fn net_capital_buckets(net_st: Decimal, net_lt: Decimal, cap: Decimal) -> CapitalNetting {
        if net_st >= dec!(0) && net_lt >= dec!(0) {
            return CapitalNetting {
                st_taxable_gain: net_st,
                lt_taxable_gain: net_lt,
                ordinary_loss_offset: dec!(0),
                carryforward: dec!(0),
            };
        }
        let combined = net_st + net_lt;
        if combined >= dec!(0) {
            // One bucket's loss is fully absorbed by the other's gain; the
            // survivor keeps the gaining bucket's character.
            let (st, lt) = if net_st < dec!(0) {
                (dec!(0), combined)
            } else {
                (combined, dec!(0))
            };
            return CapitalNetting {
                st_taxable_gain: st,
                lt_taxable_gain: lt,
                ordinary_loss_offset: dec!(0),
                carryforward: dec!(0),
            };
        }
        let loss = -combined;
        let offset = loss.min(cap);
        CapitalNetting {
            st_taxable_gain: dec!(0),
            lt_taxable_gain: dec!(0),
            ordinary_loss_offset: offset,
            carryforward: loss - offset,
        }
    }

    /// The full US-side computation: capital netting, then the standard
    /// deduction, then ordinary brackets + LTCG stacking. Pure — unit-testable
    /// without a database.
    ///
    /// Order of operations (deduction before brackets AND before the LTCG
    /// stacking start):
    ///   1. net ST/LT buckets ([`Self::net_capital_buckets`]);
    ///   2. gross ordinary = income + surviving net ST gain − capped loss offset;
    ///   3. taxable ordinary = max(0, gross ordinary − standard deduction);
    ///   4. liability = ordinary brackets over (3) + LTCG bands over the
    ///      surviving net LT gain stacked on top of (3).
    pub fn compute_us_liability(
        ordinary_income: Decimal,
        net_st: Decimal,
        net_lt: Decimal,
        tables: &TaxYearTables,
        status: &str,
    ) -> UsLiability {
        let t = tables.us_status(status);
        let n = Self::net_capital_buckets(net_st, net_lt, tables.capital_loss_ordinary_offset_cap);
        let gross_ordinary = ordinary_income + n.st_taxable_gain - n.ordinary_loss_offset;
        let taxable_ordinary = (gross_ordinary - t.standard_deduction).max(dec!(0));
        let liability = Self::calculate_us_ordinary_tax(taxable_ordinary, t)
            + Self::calculate_us_ltcg(n.lt_taxable_gain, taxable_ordinary, t);
        UsLiability {
            liability,
            taxable_ordinary,
            standard_deduction_used: t.standard_deduction,
            capital_loss_carryforward: n.carryforward,
        }
    }

    /// The marginal ORDINARY rate that applies to the next dollar of taxable
    /// ordinary income at `taxable_ordinary` — i.e. the rate a short-term
    /// harvested loss would save at the top of the user's income (a
    /// first-order estimate; a large loss can spill into a lower bracket, not
    /// modeled). Income at or below $0 still maps to the lowest bracket rate.
    /// ⚠ Rides the same UNVERIFIED constant tables as everything else.
    pub fn marginal_ordinary_rate(taxable_ordinary: Decimal, t: &UsStatusTables) -> Decimal {
        let x = taxable_ordinary.max(dec!(0));
        for b in &t.ordinary {
            if x < b.upto {
                return b.rate;
            }
        }
        t.ordinary.last().map(|b| b.rate).unwrap_or(dec!(0))
    }

    /// The marginal LONG-TERM capital-gains rate (0% / 15% / 20%) that applies
    /// to the next dollar of LT gain STACKED on top of `taxable_ordinary` —
    /// the rate a long-term harvested loss would save against future LT gains
    /// at that stacking point. Same band edges as [`Self::calculate_us_ltcg`].
    /// ⚠ Rides the same UNVERIFIED constant tables.
    pub fn marginal_ltcg_rate(taxable_ordinary: Decimal, t: &UsStatusTables) -> Decimal {
        let start = taxable_ordinary.max(dec!(0));
        if start < t.ltcg_0_top {
            dec!(0)
        } else if start < t.ltcg_15_top {
            dec!(0.15)
        } else {
            dec!(0.20)
        }
    }

    /// Long-term iff `sold > acquired + 1 calendar year` (chrono month
    /// arithmetic, NOT a 365-day count — "more than one year" is a calendar
    /// test, so e.g. a 366-day hold across a leap day that lands exactly on
    /// the anniversary is still short-term).
    ///
    /// Feb-29 convention: `checked_add_months(12)` clamps 2024-02-29 + 1 year
    /// to 2025-02-28, so the first LONG-term sale date for a leap-day lot is
    /// 2025-03-01. Postgres `date + INTERVAL '1 year'` clamps the same way,
    /// which keeps this helper in lockstep with the SQL bucket split in
    /// `calculate_yearly_tax`.
    /// ⚠ The exact-anniversary edge case is on the human-verification list
    /// (assumptions item 6).
    pub fn is_long_term(acquired: chrono::NaiveDate, sold: chrono::NaiveDate) -> bool {
        match acquired.checked_add_months(chrono::Months::new(12)) {
            Some(anniversary) => sold > anniversary,
            None => false,
        }
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
        //    T6 decomposition: the same income rows are additionally split
        //    into dividends / interest / everything-else on
        //    `category_detailed` (the values the Plaid investment sync
        //    writes). The CASE buckets are disjoint by construction, so
        //    dividend + interest + wage always re-sums to the USD total and
        //    nothing is double-counted; the bracket input stays the total.
        let income_sql = format!(
            r#"
            SELECT
                COALESCE(SUM({AMOUNT_USD_SQL}), 0) AS income_usd,
                COALESCE(SUM({AMOUNT_MXN_SQL}), 0) AS income_mxn,
                COALESCE(SUM(CASE WHEN UPPER(t.category_detailed) = 'INCOME_DIVIDENDS'
                              THEN {AMOUNT_USD_SQL} ELSE 0 END), 0) AS dividend_usd,
                COALESCE(SUM(CASE WHEN UPPER(t.category_detailed) = 'INCOME_INTEREST_EARNED'
                              THEN {AMOUNT_USD_SQL} ELSE 0 END), 0) AS interest_usd
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
        let dividend_income: Decimal = income_row.try_get("dividend_usd").unwrap_or_default();
        let interest_income: Decimal = income_row.try_get("interest_usd").unwrap_or_default();
        // Residual bucket — exact by construction (see the SQL comment).
        let wage_income = ordinary_income - dividend_income - interest_income;

        // 2. Realized capital gains from PRECISE lot disposals (actual P&L
        //    with holding periods), split short- vs long-term. Disposals
        //    inside tax-advantaged wrappers (401k/IRA/HSA/... — see
        //    TAX_ADVANTAGED_ACCOUNT_TYPES) are NOT taxable events: they're
        //    kept out of both buckets and reported separately. No disposals
        //    means no realized gains — the old "Investment Sale" blended
        //    fallback matched a category no writer ever produced and is gone.
        //    Term split: long-term iff sell_date > acquired_at + 1 CALENDAR
        //    year (interval arithmetic, not a 365-day count; Postgres clamps
        //    Feb-29 + 1 year to Feb 28, matching `Self::is_long_term`).
        //    Unknown acquisition (source lot deleted) counts as SHORT-term in
        //    the liability — the genuinely conservative direction, since ST is
        //    the higher-rate bucket. (The old code sent unknowns to long-term
        //    and called THAT conservative; it is the opposite.) Exports keep
        //    the honest "Unknown" label for those rows.
        // T12: a realized LOSS whose holding had a same-`holding_id` buy
        // within ±30 days of the sale is a WASH SALE — its loss is disallowed
        // for the year, so it is excluded from the ST/LT taxable buckets here
        // (it neither reduces the liability nor feeds the §1211(b) netting).
        // Gains are never wash sales; only losses (`realized_pnl_usd < 0`) are
        // tested, so a wash-flagged GAIN can't exist and the predicate is on
        // the loss branch only. `wash` is true when such a buy exists.
        let disp = sqlx::query(
            r#"
            SELECT
                COALESCE(SUM(CASE WHEN NOT adv.is_adv AND NOT wash.is_wash
                                   AND (l.acquired_at IS NULL
                                        OR d.sell_date <= (l.acquired_at + INTERVAL '1 year'))
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS short_term,
                COALESCE(SUM(CASE WHEN NOT adv.is_adv AND NOT wash.is_wash
                                   AND l.acquired_at IS NOT NULL
                                   AND d.sell_date > (l.acquired_at + INTERVAL '1 year')
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS long_term,
                COALESCE(SUM(CASE WHEN adv.is_adv
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS tax_advantaged,
                COALESCE(SUM(CASE WHEN NOT adv.is_adv AND wash.is_wash
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS wash_disallowed,
                COUNT(*) AS n
            FROM lot_disposals d
            LEFT JOIN holding_lots l ON l.id = d.lot_id
            JOIN accounts a ON a.id = d.account_id
            CROSS JOIN LATERAL (
                SELECT LOWER(COALESCE(a.account_type, '')) = ANY($3) AS is_adv
            ) adv
            CROSS JOIN LATERAL (
                SELECT d.realized_pnl_usd < 0 AND EXISTS (
                    SELECT 1 FROM holding_lots b
                    WHERE b.user_id = d.user_id
                      AND b.holding_id = d.holding_id
                      AND b.acquired_at BETWEEN (d.sell_date - $4::int) AND (d.sell_date + $4::int)
                ) AS is_wash
            ) wash
            WHERE d.user_id = $1
              AND EXTRACT(YEAR FROM d.sell_date)::int = $2
            "#,
        )
        .bind(user_id)
        .bind(year)
        .bind(tax_advantaged_types_param())
        .bind(WASH_SALE_WINDOW_DAYS as i32)
        .fetch_one(db)
        .await?;

        let disposal_count: i64 = disp.try_get("n").unwrap_or(0);
        let gains_from_lots = disposal_count > 0;

        let short_term_gains: Decimal = disp.try_get("short_term").unwrap_or_default();
        let long_term_gains: Decimal = disp.try_get("long_term").unwrap_or_default();
        let tax_advantaged_gains: Decimal = disp.try_get("tax_advantaged").unwrap_or_default();
        let wash_sale_disallowed_loss: Decimal =
            disp.try_get("wash_disallowed").unwrap_or_default();

        let capital_gains = short_term_gains + long_term_gains;

        // US: capital netting (ST/LT offsets, capped ordinary-loss offset,
        // carryforward), then the standard deduction, then ordinary brackets
        // with LT gains stacking on taxable ordinary income — see
        // compute_us_liability for the exact order of operations. All bracket
        // constants come from the year-keyed (and so-far UNVERIFIED) tables.
        let tables = TaxYearTables::for_year(year);
        let us = Self::compute_us_liability(
            ordinary_income,
            short_term_gains,
            long_term_gains,
            &tables,
            status,
        );
        let estimated_liability_us = us.liability;

        // MX: no preferential split here — everything flows through the ISR
        // brackets (a deliberate simplification). The tarifa is applied to an
        // MXN base: per-row-converted income plus the USD capital gains
        // converted at the year rate; the resulting MXN liability is also
        // reported back-converted to USD at that same rate so every non-`_mxn`
        // field in the response is USD.
        // (No standard deduction on the MX side — the deduction is a US
        // concept; the tarifa-over-everything simplification is unchanged.)
        let total_taxable = ordinary_income + capital_gains;
        let usd_mxn_rate_used = Self::usd_mxn_year_rate(db, year).await?;
        let total_taxable_mxn = ordinary_income_mxn + capital_gains * usd_mxn_rate_used;
        let estimated_liability_mx_mxn = Self::calculate_mx_tax(total_taxable_mxn, &tables.mx_tarifa);
        let estimated_liability_mx = if usd_mxn_rate_used > dec!(0) {
            estimated_liability_mx_mxn / usd_mxn_rate_used
        } else {
            dec!(0)
        };

        let effective_rate_us = if total_taxable > dec!(0) { estimated_liability_us / total_taxable } else { dec!(0) };
        let effective_rate_mx = if total_taxable > dec!(0) { estimated_liability_mx / total_taxable } else { dec!(0) };

        Ok(TaxEstimation {
            ordinary_income,
            dividend_income,
            interest_income,
            wage_income,
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
            bracket_year_used: tables.bracket_year,
            constants_verified: TAX_CONSTANTS_VERIFIED,
            standard_deduction_used: us.standard_deduction_used,
            capital_loss_carryforward: us.capital_loss_carryforward,
            wash_sale_disallowed_loss,
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
    /// divide native amounts by it). Long-term = sold more than one CALENDAR
    /// year after acquisition (`Self::is_long_term`); None when the source
    /// lot's acquisition date is no longer on file — those rows are labeled
    /// "Unknown" in exports but counted as SHORT-term in the liability.
    pub async fn get_lot_disposals(
        db: &PgPool,
        year: i32,
        user_id: uuid::Uuid,
    ) -> Result<Vec<TaxDisposal>> {
        // T12: per-disposal wash-sale flag — a LOSS (`realized_pnl_usd < 0`)
        // with a same-`holding_id` buy in `holding_lots` inside the ±30-day
        // window around the sale (see WASH_SALE_WINDOW_DAYS). `wash_safe_on`
        // is the first acquisition date that would NOT fall in the window
        // (sell_date + 31 days) — i.e. the date after which buying the same
        // security back no longer triggers the rule for THIS sale.
        let rows = sqlx::query(
            r#"
            SELECT h.symbol, h.name,
                   TO_CHAR(l.acquired_at, 'YYYY-MM-DD') AS acquired_date,
                   TO_CHAR(d.sell_date, 'YYYY-MM-DD') AS sell_date,
                   d.qty_sold, d.sell_price_per_unit, d.sell_fx_rate,
                   d.cost_per_unit, d.cost_fx_rate, d.realized_pnl_usd,
                   l.acquired_at AS acquired_on, d.sell_date AS sold_on,
                   a.account_type,
                   (d.realized_pnl_usd < 0 AND EXISTS (
                       SELECT 1 FROM holding_lots b
                       WHERE b.user_id = d.user_id
                         AND b.holding_id = d.holding_id
                         AND b.acquired_at BETWEEN (d.sell_date - $3::int)
                                              AND (d.sell_date + $3::int)
                   )) AS wash_sale,
                   TO_CHAR(d.sell_date + ($3::int + 1), 'YYYY-MM-DD') AS wash_safe_on
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
        .bind(WASH_SALE_WINDOW_DAYS as i32)
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
                let acquired_on: Option<chrono::NaiveDate> =
                    r.try_get::<Option<chrono::NaiveDate>, _>("acquired_on").unwrap_or(None);
                let sold_on: Option<chrono::NaiveDate> =
                    r.try_get::<Option<chrono::NaiveDate>, _>("sold_on").unwrap_or(None);
                let account_type: Option<String> =
                    r.try_get::<Option<String>, _>("account_type").unwrap_or(None);
                let tax_advantaged = is_tax_advantaged_account_type(account_type.as_deref());
                let wash_sale: bool = r.try_get("wash_sale").unwrap_or(false);
                // Only meaningful when wash_sale is true; carried regardless so
                // the field shape is stable for the frontend.
                let wash_sale_safe_after: Option<String> =
                    if wash_sale { r.try_get("wash_safe_on").ok() } else { None };
                TaxDisposal {
                    symbol: r.try_get("symbol").unwrap_or_default(),
                    name: r.try_get("name").unwrap_or_default(),
                    acquired_date: r.try_get("acquired_date").ok(),
                    sell_date: r.try_get("sell_date").unwrap_or_default(),
                    qty_sold: qty,
                    proceeds_usd,
                    cost_usd,
                    gain_usd: dec(r, "realized_pnl_usd"),
                    // Calendar-year term test, same convention as the summary
                    // SQL; None (lot gone) stays None so exports say "Unknown"
                    // even though the liability buckets it as short-term.
                    long_term: match (acquired_on, sold_on) {
                        (Some(a), Some(s)) => Some(Self::is_long_term(a, s)),
                        _ => None,
                    },
                    account_type,
                    tax_advantaged,
                    wash_sale,
                    wash_sale_safe_after,
                    from_lots: true,
                }
            })
            .collect())
    }

    /// T11: unrealized per-lot gain/loss for TAXABLE accounts only — the
    /// "what if I sell" view. Tax-advantaged wrappers
    /// (TAX_ADVANTAGED_ACCOUNT_TYPES) are excluded entirely (their internal
    /// trades aren't taxable events, so harvesting there is meaningless).
    /// Zero-qty rows are FIFO-depletion markers (no owned shares) and are
    /// filtered out, matching the dashboard's holdings handler.
    ///
    /// Valuation reconciles with `/dashboard/holdings`:
    ///   - cost basis (USD) = qty × cost_per_unit converted at the LOT's own
    ///     recorded `usd_fx_rate` (native ÷ fx for MXN, native for USD);
    ///   - current value (USD) = qty × current `holdings.price` converted at
    ///     the CURRENT USD→MXN rate (the same `fx_usd_to_mxn` the dashboard
    ///     uses), since the live price is quoted in the holding's currency;
    ///   - unrealized gain (USD) = current value − cost basis, signed.
    ///
    /// Term is the calendar-year test (`is_long_term`) as of `today`; short
    /// lots carry `days_until_long_term` and the `long_term_date` they flip.
    /// Loss lots carry an `estimated_tax_savings_usd` = |loss| × the marginal
    /// rate (ordinary for short, LTCG for long) at the user's taxable-ordinary
    /// income for `year`, and a forward-looking `wash_sale_risk` (a
    /// same-`holding_id` buy within ±30 days of `today`) plus the `safe_after`
    /// date — see [`WASH_SALE_WINDOW_DAYS`]. Savings ride the UNVERIFIED
    /// constant tables (`constants_verified`).
    pub async fn get_unrealized_lots(
        db: &PgPool,
        year: i32,
        status: &str,
        user_id: uuid::Uuid,
        today: chrono::NaiveDate,
    ) -> Result<UnrealizedLots> {
        // Current USD→MXN rate for valuing live prices — the same nearest
        // stored rate the dashboard uses, anchored at today.
        use chrono::Datelike;
        let usd_mxn_rate = Self::usd_mxn_year_rate(db, today.year()).await?;

        // The marginal rates depend on where the user's taxable ORDINARY
        // income for the year sits; derive it from the same summary math so a
        // harvest at the top of income is estimated against the right bracket.
        let est = Self::calculate_yearly_tax(db, year, status, user_id).await?;
        let tables = TaxYearTables::for_year(year);
        let t = tables.us_status(status);
        // Reconstruct taxable ordinary the summary used: gross ordinary income
        // + surviving net ST gain − capped loss offset − standard deduction.
        let netting = Self::net_capital_buckets(
            est.short_term_gains,
            est.long_term_gains,
            tables.capital_loss_ordinary_offset_cap,
        );
        let taxable_ordinary = (est.ordinary_income + netting.st_taxable_gain
            - netting.ordinary_loss_offset
            - t.standard_deduction)
            .max(dec!(0));
        let ordinary_rate = Self::marginal_ordinary_rate(taxable_ordinary, t);
        // LT gain harvested stacks on ordinary income PLUS any surviving net
        // LT gain already in play; estimate at the top of that stack.
        let ltcg_rate =
            Self::marginal_ltcg_rate(taxable_ordinary + netting.lt_taxable_gain.max(dec!(0)), t);

        let rows = sqlx::query(
            r#"
            SELECT h.symbol, h.name,
                   COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
                   a.account_type,
                   l.acquired_at,
                   TO_CHAR(l.acquired_at, 'YYYY-MM-DD') AS acquired_date,
                   l.qty, l.cost_per_unit, l.currency AS lot_currency, l.usd_fx_rate,
                   h.id AS holding_id,
                   h.price AS current_price, h.currency AS holding_currency,
                   (EXISTS (
                       SELECT 1 FROM holding_lots b
                       WHERE b.user_id = l.user_id
                         AND b.holding_id = l.holding_id
                         AND b.acquired_at BETWEEN ($3::date - $4::int)
                                              AND ($3::date + $4::int)
                   )) AS recent_buy
            FROM holding_lots l
            JOIN holdings h ON h.id = l.holding_id
            JOIN accounts a ON a.id = l.account_id
            WHERE l.user_id = $1
              AND l.qty > 0
              AND NOT (LOWER(COALESCE(a.account_type, '')) = ANY($2))
            ORDER BY l.acquired_at ASC, l.id ASC
            "#,
        )
        .bind(user_id)
        .bind(tax_advantaged_types_param())
        .bind(today)
        .bind(WASH_SALE_WINDOW_DAYS as i32)
        .fetch_all(db)
        .await?;

        let getdec = |r: &sqlx::postgres::PgRow, col: &str| -> Decimal {
            r.try_get::<Decimal, _>(col)
                .or_else(|_| r.try_get::<Option<Decimal>, _>(col).map(|o| o.unwrap_or_default()))
                .unwrap_or_default()
        };

        let lots: Vec<UnrealizedLot> = rows
            .iter()
            .map(|r| {
                let qty = getdec(r, "qty");
                let cost_px = getdec(r, "cost_per_unit");
                let lot_fx = getdec(r, "usd_fx_rate");
                let lot_ccy: String = r.try_get("lot_currency").unwrap_or_default();
                let price = getdec(r, "current_price");
                let holding_ccy: String = r.try_get("holding_currency").unwrap_or_default();

                // Cost basis in USD via the lot's OWN historical fx.
                let native_cost = qty * cost_px;
                let cost_basis_usd = match lot_ccy.to_uppercase().as_str() {
                    "MXN" => if lot_fx > Decimal::ZERO { native_cost / lot_fx } else { native_cost },
                    _ => native_cost,
                };
                // Current value in USD via the CURRENT rate (live price is
                // quoted in the holding's currency).
                let native_value = qty * price;
                let current_value_usd = match holding_ccy.to_uppercase().as_str() {
                    "MXN" => if usd_mxn_rate > Decimal::ZERO { native_value / usd_mxn_rate } else { native_value },
                    _ => native_value,
                };
                let unrealized_gain_usd = current_value_usd - cost_basis_usd;

                let acquired_on: Option<chrono::NaiveDate> =
                    r.try_get::<Option<chrono::NaiveDate>, _>("acquired_at").unwrap_or(None);
                let long_term = acquired_on
                    .map(|a| Self::is_long_term(a, today))
                    .unwrap_or(false);
                // For SHORT lots: the date it flips long-term (anniversary + 1
                // day) and the days from today until then.
                let (long_term_date, days_until_long_term) = if long_term {
                    (None, None)
                } else if let Some(a) = acquired_on {
                    let flip = a
                        .checked_add_months(chrono::Months::new(12))
                        .and_then(|d| d.succ_opt());
                    let days = flip.map(|f| (f - today).num_days().max(0));
                    (flip.map(|f| f.to_string()), days)
                } else {
                    (None, None)
                };

                // Harvest economics — only for losses.
                let is_loss = unrealized_gain_usd < Decimal::ZERO;
                let recent_buy: bool = r.try_get("recent_buy").unwrap_or(false);
                let (estimated_tax_savings_usd, wash_sale_risk, wash_sale_safe_after) = if is_loss {
                    let rate = if long_term { ltcg_rate } else { ordinary_rate };
                    let savings = (-unrealized_gain_usd) * rate;
                    let safe = if recent_buy {
                        // Buying back any time up to today+30 keeps the wash
                        // window open; the first clear date is today+31.
                        today
                            .checked_add_days(chrono::Days::new(
                                (WASH_SALE_WINDOW_DAYS + 1) as u64,
                            ))
                            .map(|d| d.to_string())
                    } else {
                        None
                    };
                    (Some(savings), recent_buy, safe)
                } else {
                    (None, false, None)
                };

                UnrealizedLot {
                    symbol: r.try_get("symbol").unwrap_or_default(),
                    name: r.try_get("name").unwrap_or_default(),
                    account_name: r.try_get("account_name").unwrap_or_default(),
                    account_type: r.try_get::<Option<String>, _>("account_type").unwrap_or(None),
                    acquired_date: r.try_get("acquired_date").ok(),
                    qty,
                    cost_basis_usd,
                    current_value_usd,
                    unrealized_gain_usd,
                    long_term,
                    days_until_long_term,
                    long_term_date,
                    estimated_tax_savings_usd,
                    wash_sale_risk,
                    wash_sale_safe_after,
                }
            })
            .collect();

        Ok(UnrealizedLots {
            short_term_gain: lots
                .iter()
                .filter(|l| !l.long_term)
                .map(|l| l.unrealized_gain_usd)
                .sum(),
            long_term_gain: lots
                .iter()
                .filter(|l| l.long_term)
                .map(|l| l.unrealized_gain_usd)
                .sum(),
            ordinary_marginal_rate: ordinary_rate,
            ltcg_marginal_rate: ltcg_rate,
            bracket_year_used: tables.bracket_year,
            constants_verified: TAX_CONSTANTS_VERIFIED,
            lots,
        })
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
    /// True = long-term (sold more than one calendar year after acquisition),
    /// false = short-term, None = unknown term (source lot deleted). Unknown
    /// rows keep this honest None — exports label them "Unknown" — but the
    /// liability counts them as short-term (the conservative, higher-rate
    /// bucket).
    pub long_term: Option<bool>,
    /// `accounts.account_type` of the account the disposal happened in
    /// (lowercase per migration 2026060801).
    pub account_type: Option<String>,
    /// True when the disposal happened inside a tax-advantaged wrapper
    /// (TAX_ADVANTAGED_ACCOUNT_TYPES) — excluded from taxable gains and from
    /// the 8949 CSV section, reported in its own section instead.
    pub tax_advantaged: bool,
    /// True when this is a wash sale (T12): a realized LOSS with a
    /// same-`holding_id` buy inside the ±30-day window around the sale (see
    /// [`WASH_SALE_WINDOW_DAYS`]). A wash-flagged loss is DISALLOWED for the
    /// year — it is excluded from the summary's taxable ST/LT gains and from
    /// the liability. Always `false` for gains. The same-`holding_id` /
    /// cross-account simplifications are on the human-verification list.
    pub wash_sale: bool,
    /// First acquisition date (YYYY-MM-DD) on which re-buying the same
    /// security would NOT trigger the wash-sale rule for this sale —
    /// `sell_date + 31 days`. `None` unless `wash_sale` is true.
    pub wash_sale_safe_after: Option<String>,
    /// True when this row comes from a precise lot disposal (always the case
    /// for `get_lot_disposals`, which only reads `lot_disposals`). Mirrors the
    /// summary's `gains_from_lots` so the screen can badge a row as precise
    /// vs. a blended estimate; the blended-cost-basis fallback the summary
    /// uses when NO lots exist produces no per-disposal rows, so a disposal in
    /// this list is never an estimate.
    pub from_lots: bool,
}

/// T11: one taxable lot's unrealized position. All money fields are **USD**
/// (see [`TaxService::get_unrealized_lots`] for the valuation convention,
/// which reconciles with `/dashboard/holdings`).
#[derive(Debug, Serialize, Deserialize)]
pub struct UnrealizedLot {
    pub symbol: String,
    pub name: String,
    /// Account display name (nickname or name) the lot sits in.
    pub account_name: String,
    /// `accounts.account_type` (lowercase) — always a TAXABLE subtype here
    /// (tax-advantaged wrappers are excluded from this view).
    pub account_type: Option<String>,
    /// Acquisition date (YYYY-MM-DD).
    pub acquired_date: Option<String>,
    pub qty: Decimal,
    /// qty × cost_per_unit, converted at the lot's recorded `usd_fx_rate`.
    #[serde(with = "rust_decimal::serde::float")]
    pub cost_basis_usd: Decimal,
    /// qty × current price, converted at the current USD→MXN rate.
    #[serde(with = "rust_decimal::serde::float")]
    pub current_value_usd: Decimal,
    /// Signed: `current_value_usd − cost_basis_usd` (negative = loss).
    #[serde(with = "rust_decimal::serde::float")]
    pub unrealized_gain_usd: Decimal,
    /// True when the lot is already long-term as of today (held more than one
    /// calendar year).
    pub long_term: bool,
    /// For SHORT lots only: days from today until the lot becomes long-term.
    /// The frontend can flag lots `<= 60` to highlight near-long-term lots.
    /// `None` for already-long-term lots (or unknown acquisition).
    pub days_until_long_term: Option<i64>,
    /// For SHORT lots only: the date (YYYY-MM-DD) the lot flips to long-term
    /// (acquisition anniversary + 1 day). `None` once long-term.
    pub long_term_date: Option<String>,
    /// Harvest economics — present only for LOSS lots: |loss| × the user's
    /// applicable marginal rate (ordinary for short, LTCG for long) at their
    /// taxable income for the selected year. ⚠ ESTIMATE — rides the UNVERIFIED
    /// constant tables (see `constants_verified` on [`UnrealizedLots`]); never
    /// present it as an authoritative figure while that flag is false.
    #[serde(
        default,
        with = "rust_decimal::serde::float_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub estimated_tax_savings_usd: Option<Decimal>,
    /// Forward-looking wash-sale guard (T12): true when a same-`holding_id`
    /// buy occurred within ±30 days of today, so harvesting this loss now
    /// would be (at least partly) a wash sale. Only set for loss lots.
    pub wash_sale_risk: bool,
    /// When `wash_sale_risk` is true: the first date (today + 31 days) a
    /// re-buy would no longer re-trigger the rule for a sale made today.
    pub wash_sale_safe_after: Option<String>,
}

/// T11 response: the per-lot unrealized rows plus ST/LT subtotals and the
/// marginal rates / verification context behind the harvest estimates.
#[derive(Debug, Serialize, Deserialize)]
pub struct UnrealizedLots {
    pub lots: Vec<UnrealizedLot>,
    /// Sum of unrealized gain (USD, signed) across SHORT-term lots.
    #[serde(with = "rust_decimal::serde::float")]
    pub short_term_gain: Decimal,
    /// Sum of unrealized gain (USD, signed) across LONG-term lots.
    #[serde(with = "rust_decimal::serde::float")]
    pub long_term_gain: Decimal,
    /// Marginal ORDINARY rate used for short-lot harvest savings (UNVERIFIED).
    #[serde(with = "rust_decimal::serde::float")]
    pub ordinary_marginal_rate: Decimal,
    /// Marginal LTCG rate used for long-lot harvest savings (UNVERIFIED).
    #[serde(with = "rust_decimal::serde::float")]
    pub ltcg_marginal_rate: Decimal,
    /// Bracket year whose tables backed the rates above.
    pub bracket_year_used: i32,
    /// Mirrors [`TAX_CONSTANTS_VERIFIED`]: while false, every
    /// `estimated_tax_savings_usd` and the marginal rates are UNVERIFIED
    /// estimates the UI must badge as pending human verification.
    pub constants_verified: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    // -----------------------------------------------------------------
    // T4 — year-keyed tables: pinned cutoffs, fallback, verification gate
    // -----------------------------------------------------------------
    // The pins below exist so any silent edit of a constant fails a test;
    // they assert what the tables CONTAIN, not that the contents are correct
    // — correctness is gated on TAX_CONSTANTS_VERIFIED / human sign-off.

    #[test]
    fn year_tables_2025_pinned_cutoffs() {
        let t = TaxYearTables::for_year(2025);
        assert_eq!(t.bracket_year, 2025);
        // One cutoff per table (per filing status where applicable).
        assert_eq!(t.us_single.ordinary[0].upto, dec!(11925));
        assert_eq!(t.us_married.ordinary[0].upto, dec!(23850));
        assert_eq!(t.us_hoh.ordinary[0].upto, dec!(17000));
        assert_eq!(t.us_single.standard_deduction, dec!(15750));
        assert_eq!(t.us_married.standard_deduction, dec!(31500));
        assert_eq!(t.us_hoh.standard_deduction, dec!(23625));
        assert_eq!(t.us_single.ltcg_0_top, dec!(48350));
        assert_eq!(t.us_married.ltcg_0_top, dec!(96700));
        assert_eq!(t.us_hoh.ltcg_0_top, dec!(64750));
        assert_eq!(t.mx_tarifa[0].cutoff, dec!(8952.49));
        assert_eq!(t.capital_loss_ordinary_offset_cap, dec!(3000));
    }

    #[test]
    fn year_tables_2026_pinned_cutoffs() {
        let t = TaxYearTables::for_year(2026);
        assert_eq!(t.bracket_year, 2026);
        assert_eq!(t.us_single.ordinary[0].upto, dec!(12400));
        assert_eq!(t.us_married.ordinary[0].upto, dec!(24800));
        assert_eq!(t.us_hoh.ordinary[0].upto, dec!(17700));
        assert_eq!(t.us_single.standard_deduction, dec!(16100));
        assert_eq!(t.us_married.standard_deduction, dec!(32200));
        assert_eq!(t.us_hoh.standard_deduction, dec!(24150));
        assert_eq!(t.us_single.ltcg_0_top, dec!(49450));
        assert_eq!(t.us_married.ltcg_0_top, dec!(98900));
        assert_eq!(t.us_hoh.ltcg_0_top, dec!(66200));
        assert_eq!(t.mx_tarifa[0].cutoff, dec!(8952.49));
        assert_eq!(t.capital_loss_ordinary_offset_cap, dec!(3000));
    }

    #[test]
    fn unknown_years_fall_back_to_nearest_table() {
        assert_eq!(TaxYearTables::for_year(2019).bracket_year, 2025);
        assert_eq!(TaxYearTables::for_year(2024).bracket_year, 2025);
        assert_eq!(TaxYearTables::for_year(2027).bracket_year, 2026);
        assert_eq!(TaxYearTables::for_year(2030).bracket_year, 2026);
    }

    #[test]
    fn constants_are_gated_unverified() {
        // Flipping this flag is a human/tax-professional decision, not a code
        // change to make a test pass — see the flag's doc comment.
        assert!(!TAX_CONSTANTS_VERIFIED);
    }

    // -----------------------------------------------------------------
    // T4 — standard deduction before brackets and before LTCG stacking
    // -----------------------------------------------------------------

    #[test]
    fn standard_deduction_applies_before_ordinary_brackets() {
        let t = TaxYearTables::for_year(2025);
        // $20,000 gross − $15,750 deduction = $4,250 taxable, all at 10%.
        let us = TaxService::compute_us_liability(dec!(20000), dec!(0), dec!(0), &t, "Single");
        assert_eq!(us.taxable_ordinary, dec!(4250));
        assert_eq!(us.liability, dec!(425.00));
        assert_eq!(us.standard_deduction_used, dec!(15750));
    }

    #[test]
    fn income_below_deduction_owes_nothing() {
        let t = TaxYearTables::for_year(2026);
        let us = TaxService::compute_us_liability(dec!(6250), dec!(0), dec!(0), &t, "Single");
        assert_eq!(us.taxable_ordinary, dec!(0));
        assert_eq!(us.liability, dec!(0));
    }

    #[test]
    fn ltcg_stacking_starts_at_post_deduction_taxable_income() {
        let t = TaxYearTables::for_year(2025);
        // Gross ordinary exactly equals the deduction → taxable ordinary 0,
        // so a LT gain the size of the whole 0% band is tax-free…
        let us = TaxService::compute_us_liability(dec!(15750), dec!(0), dec!(48350), &t, "Single");
        assert_eq!(us.taxable_ordinary, dec!(0));
        assert_eq!(us.liability, dec!(0));
        // …and one extra dollar of gain is taxed at 15%. (Pre-deduction
        // stacking would have started at 15,750 and taxed 15,751 of it.)
        let us = TaxService::compute_us_liability(dec!(15750), dec!(0), dec!(48351), &t, "Single");
        assert_eq!(us.liability, dec!(0.15));
    }

    #[test]
    fn ltcg_bands_and_ordinary_brackets_combine_after_deduction() {
        let t = TaxYearTables::for_year(2025);
        // Single 2025: $63,000 gross → 47,250 taxable ordinary.
        // Ordinary: 11,925×10% + 35,325×12% = 1,192.50 + 4,239 = 5,431.50.
        // LT $20k stacks 47,250→67,250: 1,100 free (0% top 48,350), 18,900
        // at 15% = 2,835. Total 8,266.50.
        let us = TaxService::compute_us_liability(dec!(63000), dec!(0), dec!(20000), &t, "Single");
        assert_eq!(us.taxable_ordinary, dec!(47250));
        assert_eq!(us.liability, dec!(8266.50));
    }

    #[test]
    fn ltcg_twenty_percent_top_band() {
        let t = TaxYearTables::for_year(2025);
        // A $10k gain stacked entirely above the 15% ceiling → 20%.
        let tax = TaxService::calculate_us_ltcg(dec!(10000), dec!(600000), &t.us_single);
        assert_eq!(tax, dec!(2000));
    }

    #[test]
    fn ltcg_rejects_raw_losses() {
        // Losses must go through net_capital_buckets, never the band math.
        let t = TaxYearTables::for_year(2025);
        assert_eq!(
            TaxService::calculate_us_ltcg(dec!(-5000), dec!(50000), &t.us_single),
            dec!(0)
        );
    }

    // -----------------------------------------------------------------
    // T5 — capital netting matrix (ordering rules: human-verification list)
    // -----------------------------------------------------------------

    #[test]
    fn netting_both_gains_pass_through() {
        let n = TaxService::net_capital_buckets(dec!(500), dec!(3000), dec!(3000));
        assert_eq!(n.st_taxable_gain, dec!(500));
        assert_eq!(n.lt_taxable_gain, dec!(3000));
        assert_eq!(n.ordinary_loss_offset, dec!(0));
        assert_eq!(n.carryforward, dec!(0));
    }

    #[test]
    fn netting_st_gain_absorbs_lt_loss() {
        // The pre-T5 code dropped LT losses entirely (LTCG calc returned 0).
        let n = TaxService::net_capital_buckets(dec!(5000), dec!(-2000), dec!(3000));
        assert_eq!(n.st_taxable_gain, dec!(3000));
        assert_eq!(n.lt_taxable_gain, dec!(0));
        assert_eq!(n.ordinary_loss_offset, dec!(0));
        assert_eq!(n.carryforward, dec!(0));
    }

    #[test]
    fn netting_lt_gain_absorbs_st_loss() {
        // The pre-T5 code fed the raw ST loss uncapped into ordinary income.
        let n = TaxService::net_capital_buckets(dec!(-2000), dec!(5000), dec!(3000));
        assert_eq!(n.st_taxable_gain, dec!(0));
        assert_eq!(n.lt_taxable_gain, dec!(3000));
        assert_eq!(n.ordinary_loss_offset, dec!(0));
        assert_eq!(n.carryforward, dec!(0));
    }

    #[test]
    fn netting_both_losses_caps_offset_and_carries_forward() {
        let n = TaxService::net_capital_buckets(dec!(-5000), dec!(-2000), dec!(3000));
        assert_eq!(n.st_taxable_gain, dec!(0));
        assert_eq!(n.lt_taxable_gain, dec!(0));
        assert_eq!(n.ordinary_loss_offset, dec!(3000));
        assert_eq!(n.carryforward, dec!(4000));
    }

    #[test]
    fn netting_residual_loss_after_cross_offset_is_capped() {
        // ST −5,000 vs LT +1,000 → net loss 4,000: 3,000 offsets ordinary
        // income, 1,000 carries forward.
        let n = TaxService::net_capital_buckets(dec!(-5000), dec!(1000), dec!(3000));
        assert_eq!(n.ordinary_loss_offset, dec!(3000));
        assert_eq!(n.carryforward, dec!(1000));
    }

    #[test]
    fn liability_applies_capped_loss_offset_before_deduction_math() {
        let t = TaxYearTables::for_year(2026);
        // 50,000 − 3,000 offset − 16,100 deduction = 30,900 taxable:
        // 12,400×10% + 18,500×12% = 1,240 + 2,220 = 3,460; carryforward 4,000.
        let us =
            TaxService::compute_us_liability(dec!(50000), dec!(-5000), dec!(-2000), &t, "Single");
        assert_eq!(us.taxable_ordinary, dec!(30900));
        assert_eq!(us.liability, dec!(3460.00));
        assert_eq!(us.capital_loss_carryforward, dec!(4000));
    }

    // -----------------------------------------------------------------
    // T5 — calendar-year term boundary (incl. the Feb-29 convention)
    // -----------------------------------------------------------------

    #[test]
    fn exact_anniversary_is_still_short_term() {
        // "More than one year": selling ON the anniversary is short-term.
        assert!(!TaxService::is_long_term(d(2024, 3, 10), d(2025, 3, 10)));
        assert!(TaxService::is_long_term(d(2024, 3, 10), d(2025, 3, 11)));
    }

    #[test]
    fn leap_year_span_is_not_a_day_count() {
        // 2023-06-01 → 2024-06-01 is 366 days across 2024-02-29; the old
        // `> 365 days` rule called it long-term, the calendar rule does not.
        assert!(!TaxService::is_long_term(d(2023, 6, 1), d(2024, 6, 1)));
        assert!(TaxService::is_long_term(d(2023, 6, 1), d(2024, 6, 2)));
    }

    #[test]
    fn leap_day_acquisition_anniversary_clamps_to_feb_28() {
        // Convention: 2024-02-29 + 1 year clamps to 2025-02-28 (chrono and
        // Postgres agree), so the first long-term sale date is 2025-03-01.
        assert!(!TaxService::is_long_term(d(2024, 2, 29), d(2025, 2, 28)));
        assert!(TaxService::is_long_term(d(2024, 2, 29), d(2025, 3, 1)));
    }

    #[test]
    fn well_inside_and_outside_the_boundary() {
        assert!(!TaxService::is_long_term(d(2024, 6, 1), d(2024, 12, 1)));
        assert!(TaxService::is_long_term(d(2022, 1, 1), d(2026, 6, 1)));
    }

    // -----------------------------------------------------------------
    // Pre-existing coverage
    // -----------------------------------------------------------------

    #[test]
    fn ltcg_stacks_on_ordinary_income() {
        // Single 2025, $40k taxable ordinary, $20k LT gain: stacked 40k→60k.
        // The 0% band tops out at 48,350, so 8,350 is free and 11,650 at 15%.
        let t = TaxYearTables::for_year(2025);
        let tax = TaxService::calculate_us_ltcg(dec!(20000), dec!(40000), &t.us_single);
        assert_eq!(tax, dec!(1747.50));
    }

    // -----------------------------------------------------------------
    // T11 — marginal-rate helpers behind the harvest-savings estimate
    // -----------------------------------------------------------------

    #[test]
    fn marginal_ordinary_rate_picks_the_bracket_of_the_next_dollar() {
        let t = TaxYearTables::for_year(2026);
        let s = &t.us_single;
        // 0 / below first cutoff → lowest bracket.
        assert_eq!(TaxService::marginal_ordinary_rate(dec!(0), s), dec!(0.10));
        assert_eq!(TaxService::marginal_ordinary_rate(dec!(-100), s), dec!(0.10));
        // Inside the 12% band (first cutoff 12,400, second 50,400).
        assert_eq!(TaxService::marginal_ordinary_rate(dec!(30000), s), dec!(0.12));
        // Above the top cutoff → top rate.
        assert_eq!(TaxService::marginal_ordinary_rate(dec!(2_000_000), s), dec!(0.37));
    }

    #[test]
    fn marginal_ltcg_rate_tracks_the_stacking_band() {
        let t = TaxYearTables::for_year(2026);
        let s = &t.us_single; // ltcg_0_top 49,450, ltcg_15_top 545,500
        assert_eq!(TaxService::marginal_ltcg_rate(dec!(0), s), dec!(0));
        assert_eq!(TaxService::marginal_ltcg_rate(dec!(49_449), s), dec!(0));
        assert_eq!(TaxService::marginal_ltcg_rate(dec!(49_450), s), dec!(0.15));
        assert_eq!(TaxService::marginal_ltcg_rate(dec!(100_000), s), dec!(0.15));
        assert_eq!(TaxService::marginal_ltcg_rate(dec!(545_500), s), dec!(0.20));
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
}
