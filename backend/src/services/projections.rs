use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde::{Deserialize, Serialize};

/// Projection inputs.
///
/// Everything is computed in **real (today's) dollars**. The caller passes a
/// *nominal* expected return plus an inflation assumption; internally we deflate
/// to a real return via the Fisher relation so that `annual_expenses`,
/// `monthly_contribution`, the FI number and every chart point are all in
/// today's purchasing power. This is the single biggest correctness fix over
/// the old model, where a fixed `annual_expenses` and the 4% rule were applied
/// against a nominal balance that silently inflated away.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProjectionRequest {
    pub start_balance: f64,
    /// Contribution per month during the accumulation phase (today's $).
    pub monthly_contribution: f64,
    /// NOMINAL expected annual return (e.g. 0.07).
    pub annual_return_rate: f64,
    /// Annual spending in retirement, today's $ (drives the decumulation phase
    /// and the FI number).
    pub annual_expenses: f64,
    /// Withdrawal rate used for the FI number, e.g. 0.04.
    pub withdrawal_rate: f64,
    /// Total horizon in years (accumulation + decumulation).
    pub years: i32,

    /// Assumed annual inflation. Defaults to 0.03 when omitted.
    #[serde(default)]
    pub annual_inflation_rate: Option<f64>,
    /// Annual return volatility (stdev) for the Monte Carlo. Defaults to 0.13,
    /// a defensible figure for a ~70/30 portfolio in real terms.
    #[serde(default)]
    pub return_volatility: Option<f64>,
    /// Years until contributions stop and withdrawals begin. When omitted the
    /// whole horizon is accumulation (no decumulation) — the legacy behaviour.
    #[serde(default)]
    pub years_to_retirement: Option<i32>,
    /// Monte Carlo trial count. Defaults to 1000.
    #[serde(default)]
    pub monte_carlo_trials: Option<i32>,
    /// Part-time income in retirement for the Barista-FIRE number (today's $/mo).
    #[serde(default)]
    pub barista_monthly_income: Option<f64>,
    /// Effective annual tax drag on returns (e.g. 0.015 = 1.5pp haircut). A
    /// deliberate simplification — real tax hits withdrawals/gains, but a flat
    /// return haircut is a defensible first-order model. Default 0.
    #[serde(default)]
    pub annual_tax_drag: Option<f64>,
    /// When true, the Monte Carlo applies Guyton-Klinger guardrails in
    /// retirement: cut spending 10% when the withdrawal rate drifts >20% above
    /// the initial rate (portfolio fell), raise it 10% when it drifts >20%
    /// below (portfolio grew). Models spending flexibility, which lifts the
    /// success rate. Default false (fixed real spending).
    #[serde(default)]
    pub withdrawal_guardrails: Option<bool>,
    /// Optional RNG seed so tests are deterministic. Omit in production.
    #[serde(default)]
    pub mc_seed: Option<u64>,

    // ---- "Retire in Mexico" scenario (all optional — absent = legacy
    // single-currency behavior, byte-identical response) ----
    /// Scenario toggle. When true, `annual_expenses` is IGNORED and the
    /// effective retirement spend is derived from the USD/MXN split below —
    /// a pure input transformation in front of the unchanged engine.
    #[serde(default)]
    pub mx_scenario: Option<bool>,
    /// Portion of retirement spending that stays in US dollars (today's $/yr).
    #[serde(default)]
    pub annual_expenses_usd_portion: Option<f64>,
    /// Portion of retirement spending in Mexican pesos (today's MXN/yr).
    #[serde(default)]
    pub annual_expenses_mxn_portion: Option<f64>,
    /// Current USD→MXN rate. The handler fills this from the latest stored
    /// `exchange_rates` row when the client omits it; the hard fallback
    /// mirrors `services::tax::USD_MXN_ROW_RATE_SQL`'s 20.0.
    #[serde(default)]
    pub usd_mxn_rate: Option<f64>,
    /// Assumed long-run *real* drift of the USD/MXN rate, fraction per year
    /// (0.02 = the peso weakens 2%/yr beyond inflation differentials).
    /// Default 0 = purchasing-power parity holds — the neutral long-run
    /// assumption, which makes turning the scenario on with an all-MXN split
    /// an identity. Clamped to ±10%/yr.
    #[serde(default)]
    pub fx_annual_drift: Option<f64>,
}

impl ProjectionRequest {
    fn inflation(&self) -> f64 {
        self.annual_inflation_rate.unwrap_or(0.03)
    }
    fn volatility(&self) -> f64 {
        self.return_volatility.unwrap_or(0.13).max(0.0)
    }
    fn trials(&self) -> usize {
        self.monte_carlo_trials.unwrap_or(1000).clamp(1, 50_000) as usize
    }
    /// Projection horizon in years, clamped to a sane 0..=120. Bounding this
    /// is a safety guardrail, not just tidiness: `years` comes straight off
    /// an authenticated query param, and an unbounded value blows up both the
    /// deterministic loop (`years * 12` overflows i32) and the Monte Carlo
    /// allocation (`vec![_; years + 1]` → multi-GB → process-wide OOM abort).
    /// Mirrors the `trials()` clamp.
    fn years(&self) -> i32 {
        self.years.clamp(0, 120)
    }
    /// Year at which the accumulation phase ends. Clamped to the horizon.
    fn retire_year(&self) -> i32 {
        self.years_to_retirement.unwrap_or(self.years()).clamp(0, self.years())
    }
    /// Real (inflation-adjusted) annual return via the Fisher relation.
    fn real_return(&self) -> f64 {
        real_return(self.annual_return_rate, self.inflation())
    }
    fn mx_on(&self) -> bool {
        self.mx_scenario.unwrap_or(false)
    }
    /// FX drift clamped to a sane ±10%/yr — it comes straight off a query
    /// param, and an absurd drift compounds into inf/0 rates over a long
    /// horizon (same guardrail spirit as `years()` / `trials()`).
    fn fx_drift(&self) -> f64 {
        let d = self.fx_annual_drift.unwrap_or(0.0);
        if d.is_finite() {
            d.clamp(-0.10, 0.10)
        } else {
            0.0
        }
    }
    /// Current USD→MXN rate with the house hard fallback (20.0 — the same
    /// last-resort constant as `USD_MXN_ROW_RATE_SQL` in services::tax).
    fn fx_rate_today(&self) -> f64 {
        match self.usd_mxn_rate {
            Some(r) if r.is_finite() && r > 0.0 => r,
            _ => FALLBACK_USD_MXN_RATE,
        }
    }
}

/// Last-resort USD→MXN rate, matching the SQL fallback in
/// `services::tax::USD_MXN_ROW_RATE_SQL` so the two FX rules can't disagree.
const FALLBACK_USD_MXN_RATE: f64 = 20.0;

#[derive(Debug, Serialize, Deserialize)]
pub struct ProjectionPoint {
    pub year: i32,
    pub month: i32,
    pub balance: f64,
    pub total_contributions: f64,
    pub total_growth: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FireMetrics {
    pub fi_number: f64,
    pub current_progress_pct: f64,
    pub estimated_years_to_fi: Option<f64>,
    pub monthly_income_at_retirement: f64,
    /// Real return actually used internally (after deflating for inflation).
    pub real_return_rate: f64,
    /// Amount you'd need invested **today** so that, with zero further
    /// contributions, growth alone reaches the FI number by retirement.
    pub coast_fi_number: f64,
    pub coast_fi_achieved: bool,
    /// FI number if part-time (Barista) income covers part of expenses.
    pub barista_fi_number: f64,
}

/// One year of the Monte Carlo fan: the spread of outcomes at that year.
#[derive(Debug, Serialize, Deserialize)]
pub struct PercentilePoint {
    pub year: i32,
    pub p10: f64,
    pub p25: f64,
    pub p50: f64,
    pub p75: f64,
    pub p90: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MonteCarloResult {
    pub trials: i32,
    /// Fraction of trials where the portfolio survived the whole horizon.
    /// Framed as "probability the plan succeeds without a spending
    /// adjustment" — 100% is over-conservative; 80-90% is the usual target.
    pub success_rate: f64,
    pub percentiles: Vec<PercentilePoint>,
    pub median_ending_balance: f64,
}

/// Derived figures for the "Retire in Mexico" scenario. Present only when
/// the request set `mx_scenario=true`; the block re-states the headline FIRE
/// outputs in both currencies at the projected at-retirement rate.
///
/// ⚠ Simplification: the MXN portion is converted at the *at-retirement*
/// rate and held constant through decumulation (the engine's
/// `annual_expenses` is a single real-USD figure). With nonzero drift the
/// true USD cost of peso spending would keep drifting during retirement;
/// this snapshot is the defensible first-order model, matching how the FI
/// number itself is an at-retirement construct (4% rule at the boundary).
#[derive(Debug, Serialize, Deserialize)]
pub struct MxScenarioResult {
    /// The single USD/yr figure the engine actually ran with:
    /// `usd_portion + mxn_portion / fx_rate_at_retirement`.
    pub effective_annual_expenses_usd: f64,
    /// Echo of the (clamped) inputs, so the client can render provenance.
    pub annual_expenses_usd_portion: f64,
    pub annual_expenses_mxn_portion: f64,
    pub fx_rate_today: f64,
    /// `fx_rate_today * (1 + drift)^years_to_retirement`.
    pub fx_rate_at_retirement: f64,
    pub fx_annual_drift: f64,
    /// `fire_metrics.fi_number`, restated for the dual-currency panel.
    pub fi_number_usd: f64,
    /// FI number in pesos at the at-retirement rate.
    pub fi_number_mxn: f64,
    pub monthly_income_at_retirement_usd: f64,
    pub monthly_income_at_retirement_mxn: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ProjectionResponse {
    pub points: Vec<ProjectionPoint>,
    pub fire_metrics: FireMetrics,
    pub monte_carlo: MonteCarloResult,
    /// Always true today — all figures are in real (today's) dollars.
    pub real_dollars: bool,
    /// "Retire in Mexico" scenario block; omitted from the JSON entirely for
    /// legacy single-currency requests so their contract is unchanged.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default)]
    pub mx_scenario: Option<MxScenarioResult>,
}

/// Inputs of the MX transformation, carried from [`apply_mx_scenario`] to the
/// response block once the FIRE metrics exist.
struct MxInputs {
    usd_portion: f64,
    mxn_portion: f64,
    rate_today: f64,
    rate_at_retirement: f64,
    drift: f64,
    effective_annual_expenses: f64,
}

/// The "Retire in Mexico" input transformation: collapse the USD/MXN
/// spending split + FX drift into the single real-USD `annual_expenses` the
/// unchanged engine consumes. Returns the request as-is when the scenario is
/// off. Portions are clamped to [0, 1e12] — they come off query params and an
/// absurd value would poison every downstream f64.
fn apply_mx_scenario(req: &ProjectionRequest) -> (ProjectionRequest, Option<MxInputs>) {
    if !req.mx_on() {
        return (req.clone(), None);
    }
    let sane = |v: Option<f64>| match v {
        Some(x) if x.is_finite() => x.clamp(0.0, 1e12),
        _ => 0.0,
    };
    let usd_portion = sane(req.annual_expenses_usd_portion);
    let mxn_portion = sane(req.annual_expenses_mxn_portion);
    let rate_today = req.fx_rate_today();
    let drift = req.fx_drift();
    // Drift compounds over the accumulation phase only (see MxScenarioResult
    // docs for why the at-retirement snapshot is the model). Floor the rate
    // so a pathological drift can never divide by ~0.
    let years = f64::from(req.retire_year());
    let rate_at_retirement = (rate_today * (1.0 + drift).powf(years)).max(1e-6);
    let effective_annual_expenses = usd_portion + mxn_portion / rate_at_retirement;
    let mut eff = req.clone();
    eff.annual_expenses = effective_annual_expenses;
    (
        eff,
        Some(MxInputs {
            usd_portion,
            mxn_portion,
            rate_today,
            rate_at_retirement,
            drift,
            effective_annual_expenses,
        }),
    )
}

/// Fisher relation: real = (1 + nominal) / (1 + inflation) - 1.
fn real_return(nominal: f64, inflation: f64) -> f64 {
    (1.0 + nominal) / (1.0 + inflation) - 1.0
}

/// Calculate a wealth projection in real (today's) dollars.
pub fn calculate_projection(req: &ProjectionRequest) -> ProjectionResponse {
    // "Retire in Mexico" is an input transformation, not a new engine: derive
    // the effective USD annual_expenses first, then run the unchanged model.
    let (effective_req, mx_inputs) = apply_mx_scenario(req);
    let req = &effective_req;
    // Tax drag lowers the effective real return everywhere it's applied
    // (growth, FI-date, coast discount, Monte Carlo).
    let real = req.real_return() - req.annual_tax_drag.unwrap_or(0.0).max(0.0);
    let monthly_rate = (1.0 + real).powf(1.0 / 12.0) - 1.0;
    let retire_month = req.retire_year() * 12;
    // Guaranteed retirement income (Social Security / pension / part-time)
    // offsets spending during decumulation, so the portfolio only has to fund
    // the shortfall. Floored at 0: when income covers expenses you simply stop
    // drawing down — you don't pump the surplus back into the portfolio (that
    // overstates growth, and it would disagree with barista_fi_number, which
    // already floors the shortfall at 0).
    let other_monthly_income = req.barista_monthly_income.unwrap_or(0.0);
    let monthly_withdrawal = (req.annual_expenses / 12.0 - other_monthly_income).max(0.0);

    let mut points = Vec::new();
    let mut balance = req.start_balance;
    let mut total_contributions = 0.0;
    let mut total_growth = 0.0;

    points.push(ProjectionPoint {
        year: 0,
        month: 0,
        balance,
        total_contributions: 0.0,
        total_growth: 0.0,
    });

    // Deterministic median path: accumulate up to the retirement month, then
    // draw down inflation-adjusted spending (constant in real terms).
    let mut balance_at_retirement = balance;
    for m in 1..=(req.years() * 12) {
        let growth = balance * monthly_rate;
        total_growth += growth;
        if m <= retire_month {
            balance += growth + req.monthly_contribution;
            total_contributions += req.monthly_contribution;
        } else {
            balance += growth - monthly_withdrawal;
        }
        if balance < 0.0 {
            balance = 0.0;
        }
        if m == retire_month {
            balance_at_retirement = balance;
        }
        points.push(ProjectionPoint {
            year: m / 12,
            month: m % 12,
            balance,
            total_contributions,
            total_growth,
        });
    }
    // If retirement == 0 (or horizon), anchor the income figure sensibly.
    if retire_month == 0 {
        balance_at_retirement = req.start_balance;
    } else if retire_month >= req.years() * 12 {
        balance_at_retirement = balance;
    }

    // ---- FIRE metrics (all real $) ----
    let fi_number = if req.withdrawal_rate > 0.0 {
        req.annual_expenses / req.withdrawal_rate
    } else {
        0.0
    };
    let current_progress_pct = if fi_number > 0.0 {
        (req.start_balance / fi_number) * 100.0
    } else {
        0.0
    };
    let estimated_years_to_fi = calculate_years_to_fi(
        req.start_balance,
        req.monthly_contribution,
        real,
        fi_number,
    );
    let monthly_income_at_retirement = balance_at_retirement * req.withdrawal_rate / 12.0;

    // Coast FIRE: present value of the FI number discounted at the real return
    // over the years left until retirement. If you already have this much, you
    // can stop contributing and growth alone gets you there.
    let years_to_retire = req.retire_year() as f64;
    let coast_fi_number = if (1.0 + real) > 0.0 {
        fi_number / (1.0 + real).powf(years_to_retire)
    } else {
        fi_number
    };
    let coast_fi_achieved = req.start_balance >= coast_fi_number && coast_fi_number > 0.0;

    // Barista FIRE: part-time income covers part of expenses, so the portfolio
    // only has to fund the shortfall.
    let barista_income = req.barista_monthly_income.unwrap_or(0.0) * 12.0;
    let barista_fi_number = if req.withdrawal_rate > 0.0 {
        ((req.annual_expenses - barista_income).max(0.0)) / req.withdrawal_rate
    } else {
        0.0
    };

    let fire_metrics = FireMetrics {
        fi_number,
        current_progress_pct,
        estimated_years_to_fi,
        monthly_income_at_retirement,
        real_return_rate: real,
        coast_fi_number,
        coast_fi_achieved,
        barista_fi_number,
    };

    let monte_carlo = run_monte_carlo(req, real);

    // Restate the headline FIRE outputs in both currencies at the projected
    // at-retirement rate. Multiplication (never a re-derivation) so the USD
    // and MXN figures can't drift apart from the engine's own numbers.
    let mx_scenario = mx_inputs.map(|mx| MxScenarioResult {
        effective_annual_expenses_usd: mx.effective_annual_expenses,
        annual_expenses_usd_portion: mx.usd_portion,
        annual_expenses_mxn_portion: mx.mxn_portion,
        fx_rate_today: mx.rate_today,
        fx_rate_at_retirement: mx.rate_at_retirement,
        fx_annual_drift: mx.drift,
        fi_number_usd: fire_metrics.fi_number,
        fi_number_mxn: fire_metrics.fi_number * mx.rate_at_retirement,
        monthly_income_at_retirement_usd: fire_metrics.monthly_income_at_retirement,
        monthly_income_at_retirement_mxn: fire_metrics.monthly_income_at_retirement
            * mx.rate_at_retirement,
    });

    ProjectionResponse {
        points,
        fire_metrics,
        monte_carlo,
        real_dollars: true,
        mx_scenario,
    }
}

/// Years to reach `target` from `start` contributing `monthly`, growing at the
/// given real annual rate. Closed-form future-value-of-annuity inversion.
fn calculate_years_to_fi(start: f64, monthly: f64, annual_rate: f64, target: f64) -> Option<f64> {
    if target <= 0.0 {
        return None;
    }
    if start >= target {
        return Some(0.0);
    }
    let m_rate = (1.0 + annual_rate).powf(1.0 / 12.0) - 1.0;
    if m_rate.abs() < 1e-12 {
        if monthly <= 0.0 {
            return None;
        }
        return Some((target - start) / (monthly * 12.0));
    }
    // target = (start + monthly/r)(1+r)^n - monthly/r
    // n = log((target + pmt/r) / (start + pmt/r)) / log(1+r)
    let pmt_over_r = monthly / m_rate;
    let numerator = target + pmt_over_r;
    let denominator = start + pmt_over_r;
    if numerator <= 0.0 || denominator <= 0.0 {
        return None;
    }
    let ratio = numerator / denominator;
    if ratio <= 0.0 {
        return None;
    }
    let n = ratio.ln() / (1.0 + m_rate).ln();
    if n.is_finite() && n >= 0.0 {
        Some(n / 12.0)
    } else {
        None
    }
}

/// Standard-normal sample via Box-Muller (rand 0.8 has no `rand_distr`).
fn standard_normal(rng: &mut StdRng) -> f64 {
    let u1: f64 = rng.gen::<f64>().max(1e-12);
    let u2: f64 = rng.gen::<f64>();
    (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
}

/// Monte Carlo with lognormal annual real returns.
///
/// The growth factor is `exp(ln(1+μ) - σ²/2 + σz)`, whose **arithmetic** mean
/// is exactly `1+μ`. The `-σ²/2` drift term is the detail naive implementations
/// miss; without it the lognormal draws are biased low. Success = the portfolio
/// stayed positive through the whole horizon.
fn run_monte_carlo(req: &ProjectionRequest, real: f64) -> MonteCarloResult {
    let trials = req.trials();
    let horizon = req.years() as usize;
    let retire_year = req.retire_year();
    let sigma = req.volatility();
    let annual_contribution = req.monthly_contribution * 12.0;
    // Net of guaranteed retirement income, floored at 0 (see deterministic
    // path above — surplus income is not reinvested into the portfolio).
    let annual_spend =
        (req.annual_expenses - req.barista_monthly_income.unwrap_or(0.0) * 12.0).max(0.0);
    let drift = (1.0 + real).ln() - 0.5 * sigma * sigma;
    // Guardrails only make sense when the portfolio is actually being drawn
    // down (net positive spend).
    let guardrails = req.withdrawal_guardrails.unwrap_or(false) && annual_spend > 0.0;

    let mut rng = match req.mc_seed {
        Some(s) => StdRng::seed_from_u64(s),
        None => StdRng::from_entropy(),
    };

    // by_year[y] collects every trial's balance at year y for percentiles.
    let mut by_year: Vec<Vec<f64>> = vec![Vec::with_capacity(trials); horizon + 1];
    let mut successes = 0usize;

    for _ in 0..trials {
        let mut bal = req.start_balance;
        by_year[0].push(bal);
        // Guyton-Klinger state: the current (possibly adjusted) withdrawal and
        // the initial withdrawal rate captured at the start of retirement.
        let mut withdrawal = annual_spend;
        let mut initial_rate: Option<f64> = None;
        // y is used as a value (retire_year comparison), not just an index
        #[allow(clippy::needless_range_loop)]
        for y in 1..=horizon {
            let z = standard_normal(&mut rng);
            let growth = (drift + sigma * z).exp();
            if (y as i32) <= retire_year {
                bal = bal * growth + annual_contribution;
            } else {
                if guardrails && bal > 0.0 {
                    match initial_rate {
                        None => initial_rate = Some(withdrawal / bal),
                        Some(ir) => {
                            let cur = withdrawal / bal;
                            if cur > ir * 1.2 {
                                withdrawal *= 0.9; // capital-preservation cut
                            } else if cur < ir * 0.8 {
                                withdrawal *= 1.1; // prosperity raise
                            }
                        }
                    }
                }
                let spend = if guardrails { withdrawal } else { annual_spend };
                bal = bal * growth - spend;
            }
            if bal < 0.0 {
                bal = 0.0;
            }
            by_year[y].push(bal);
        }
        if by_year[horizon].last().copied().unwrap_or(0.0) > 0.0 {
            successes += 1;
        }
    }

    let percentiles = by_year
        .iter()
        .enumerate()
        .map(|(y, balances)| {
            let mut sorted = balances.clone();
            sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            PercentilePoint {
                year: y as i32,
                p10: percentile(&sorted, 0.10),
                p25: percentile(&sorted, 0.25),
                p50: percentile(&sorted, 0.50),
                p75: percentile(&sorted, 0.75),
                p90: percentile(&sorted, 0.90),
            }
        })
        .collect();

    let median_ending_balance = {
        let mut sorted = by_year[horizon].clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        percentile(&sorted, 0.50)
    };

    MonteCarloResult {
        trials: trials as i32,
        success_rate: if trials > 0 {
            successes as f64 / trials as f64
        } else {
            0.0
        },
        percentiles,
        median_ending_balance,
    }
}

/// Linear-interpolated percentile of a pre-sorted slice. `p` in [0,1].
fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    if sorted.len() == 1 {
        return sorted[0];
    }
    let rank = p * (sorted.len() - 1) as f64;
    let lo = rank.floor() as usize;
    let hi = rank.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        let frac = rank - lo as f64;
        sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_req() -> ProjectionRequest {
        ProjectionRequest {
            start_balance: 100_000.0,
            monthly_contribution: 1000.0,
            annual_return_rate: 0.07,
            annual_expenses: 40_000.0,
            withdrawal_rate: 0.04,
            years: 30,
            annual_inflation_rate: Some(0.03),
            return_volatility: Some(0.13),
            years_to_retirement: Some(20),
            monte_carlo_trials: Some(500),
            barista_monthly_income: Some(1000.0),
            annual_tax_drag: None,
            withdrawal_guardrails: None,
            mc_seed: Some(42),
            mx_scenario: None,
            annual_expenses_usd_portion: None,
            annual_expenses_mxn_portion: None,
            usd_mxn_rate: None,
            fx_annual_drift: None,
        }
    }

    #[test]
    fn real_return_deflates_nominal() {
        // 7% nominal, 3% inflation -> ~3.88% real.
        let r = real_return(0.07, 0.03);
        assert!((r - 0.038835).abs() < 1e-4, "got {r}");
    }

    #[test]
    fn monthly_points_count_matches_horizon() {
        let res = calculate_projection(&base_req());
        assert_eq!(res.points.len() as i32, base_req().years * 12 + 1);
        assert!(res.real_dollars);
    }

    #[test]
    fn absurd_years_is_clamped_not_ooming() {
        // Regression: `years` is an unvalidated query param. A huge value
        // overflowed `years * 12` (deterministic loop) and allocated
        // `vec![_; years + 1]` (~tens of GB → process-wide OOM abort) in the
        // Monte Carlo. It must clamp to the 120-year cap and return promptly.
        let mut req = base_req();
        req.years = 1_000_000_000;
        let res = calculate_projection(&req);
        // Horizon clamped to 120 years → 120*12 + 1 monthly points.
        assert_eq!(res.points.len(), 120 * 12 + 1);
        assert_eq!(res.monte_carlo.percentiles.len(), 121);
    }

    #[test]
    fn fi_number_uses_real_dollars() {
        let res = calculate_projection(&base_req());
        // 40,000 / 0.04 = 1,000,000.
        assert!((res.fire_metrics.fi_number - 1_000_000.0).abs() < 1e-6);
        assert!((res.fire_metrics.current_progress_pct - 10.0).abs() < 1e-6);
        // Real return strictly below the nominal 7%.
        assert!(res.fire_metrics.real_return_rate < 0.07);
    }

    #[test]
    fn decumulation_reduces_balance_after_retirement() {
        // Aggressive draw, modest portfolio: balance should fall in retirement.
        let mut req = base_req();
        req.annual_expenses = 80_000.0;
        req.monthly_contribution = 500.0;
        req.years_to_retirement = Some(10);
        req.years = 40;
        let res = calculate_projection(&req);
        let at_retire = res
            .points
            .iter()
            .find(|p| p.year == 10 && p.month == 0)
            .unwrap()
            .balance;
        let at_end = res.points.last().unwrap().balance;
        assert!(
            at_end < at_retire,
            "expected drawdown: retire={at_retire}, end={at_end}"
        );
    }

    #[test]
    fn pure_accumulation_when_no_retirement_year() {
        // No years_to_retirement -> never withdraw -> monotonic growth.
        let mut req = base_req();
        req.years_to_retirement = None;
        let res = calculate_projection(&req);
        let last = res.points.last().unwrap().balance;
        assert!(last > req.start_balance);
    }

    #[test]
    fn coast_fire_number_is_present_value_of_fi() {
        let res = calculate_projection(&base_req());
        // Coast number must be below the full FI number (discounted) and > 0.
        assert!(res.fire_metrics.coast_fi_number > 0.0);
        assert!(res.fire_metrics.coast_fi_number < res.fire_metrics.fi_number);
    }

    #[test]
    fn barista_number_below_full_fi() {
        let res = calculate_projection(&base_req());
        // 1000/mo part-time income lowers the required portfolio.
        assert!(res.fire_metrics.barista_fi_number < res.fire_metrics.fi_number);
        assert!(res.fire_metrics.barista_fi_number > 0.0);
    }

    #[test]
    fn monte_carlo_success_rate_in_bounds_and_seeded() {
        let res = calculate_projection(&base_req());
        let mc = &res.monte_carlo;
        assert_eq!(mc.trials, 500);
        assert!(mc.success_rate >= 0.0 && mc.success_rate <= 1.0);
        // Yearly fan: horizon + 1 entries, monotonic percentile ordering.
        assert_eq!(mc.percentiles.len() as i32, base_req().years + 1);
        for p in &mc.percentiles {
            assert!(p.p10 <= p.p25 + 1e-6);
            assert!(p.p25 <= p.p50 + 1e-6);
            assert!(p.p50 <= p.p75 + 1e-6);
            assert!(p.p75 <= p.p90 + 1e-6);
        }
        // Same seed -> identical success rate (determinism).
        let res2 = calculate_projection(&base_req());
        assert_eq!(mc.success_rate, res2.monte_carlo.success_rate);
    }

    #[test]
    fn healthy_plan_has_high_success_rate() {
        // Big portfolio, modest spending, long accumulation -> should rarely fail.
        let mut req = base_req();
        req.start_balance = 800_000.0;
        req.monthly_contribution = 3000.0;
        req.annual_expenses = 30_000.0;
        req.years_to_retirement = Some(15);
        req.years = 45;
        let res = calculate_projection(&req);
        assert!(
            res.monte_carlo.success_rate > 0.8,
            "expected >80% success, got {}",
            res.monte_carlo.success_rate
        );
    }

    #[test]
    fn retirement_income_improves_success_and_ending_balance() {
        // A plan that leans on the portfolio for all spending vs the same plan
        // with guaranteed retirement income covering part of it. The income
        // must raise both the Monte Carlo success rate and the median ending
        // balance (same seed → apples to apples).
        let mut req = base_req();
        req.start_balance = 400_000.0;
        req.monthly_contribution = 500.0;
        req.annual_expenses = 60_000.0;
        req.years_to_retirement = Some(10);
        req.years = 40;

        req.barista_monthly_income = Some(0.0);
        let without = calculate_projection(&req);

        req.barista_monthly_income = Some(3000.0); // covers $36k of the $60k spend
        let with = calculate_projection(&req);

        assert!(
            with.monte_carlo.success_rate > without.monte_carlo.success_rate,
            "income should raise success: {} vs {}",
            with.monte_carlo.success_rate,
            without.monte_carlo.success_rate
        );
        assert!(
            with.monte_carlo.median_ending_balance
                > without.monte_carlo.median_ending_balance,
            "income should raise the median ending balance"
        );
        // Deterministic path: the final balance is higher with income too.
        assert!(
            with.points.last().unwrap().balance > without.points.last().unwrap().balance
        );
    }

    #[test]
    fn tax_drag_lowers_returns_and_ending_balance() {
        let mut req = base_req();
        req.annual_tax_drag = Some(0.0);
        let no_tax = calculate_projection(&req);
        req.annual_tax_drag = Some(0.015);
        let taxed = calculate_projection(&req);
        assert!(
            taxed.fire_metrics.real_return_rate < no_tax.fire_metrics.real_return_rate,
            "tax drag must lower the effective real return"
        );
        assert!(
            taxed.points.last().unwrap().balance < no_tax.points.last().unwrap().balance,
            "tax drag must lower the projected ending balance"
        );
    }

    #[test]
    fn guardrails_improve_success_on_stressed_plan() {
        // 6% withdrawal off the bat with no contributions — a plan stressed
        // enough that spending flexibility clearly helps.
        let mut req = base_req();
        req.start_balance = 600_000.0;
        req.monthly_contribution = 0.0;
        req.annual_expenses = 36_000.0;
        req.barista_monthly_income = Some(0.0);
        req.years_to_retirement = Some(0); // retire immediately
        req.years = 40;
        req.monte_carlo_trials = Some(1000);

        req.withdrawal_guardrails = Some(false);
        let fixed = calculate_projection(&req).monte_carlo.success_rate;
        req.withdrawal_guardrails = Some(true);
        let guarded = calculate_projection(&req).monte_carlo.success_rate;

        assert!(
            guarded > fixed,
            "guardrails should raise success on a stressed plan: {guarded} vs {fixed}"
        );
    }

    // ---- "Retire in Mexico" scenario (input-transformation layer) ----

    /// base_req with the MX scenario on: the $40k spend expressed entirely in
    /// pesos at rate 20 (40,000 × 20 = 800,000 MXN/yr), zero drift.
    fn mx_req() -> ProjectionRequest {
        let mut req = base_req();
        req.mx_scenario = Some(true);
        req.annual_expenses_usd_portion = Some(0.0);
        req.annual_expenses_mxn_portion = Some(800_000.0);
        req.usd_mxn_rate = Some(20.0);
        req.fx_annual_drift = Some(0.0);
        // Make the legacy field obviously wrong so the test proves it's
        // ignored when the scenario is on.
        req.annual_expenses = 123_456.0;
        req
    }

    #[test]
    fn mx_scenario_absent_leaves_response_unchanged() {
        // Regression guard: users who ignore the new controls must see
        // byte-identical numbers. No mx block, same FI number as ever.
        let res = calculate_projection(&base_req());
        assert!(res.mx_scenario.is_none());
        assert!((res.fire_metrics.fi_number - 1_000_000.0).abs() < 1e-6);
        // And the block is absent from the serialized JSON, not null.
        let json = serde_json::to_string(&res).unwrap();
        assert!(!json.contains("mx_scenario"));
    }

    #[test]
    fn mx_all_mxn_split_at_zero_drift_is_an_identity() {
        // 800k MXN at rate 20 with 0 drift == the legacy $40k request: the
        // FI number, expected path and Monte Carlo must all match exactly
        // (same seed), proving this is a pure input transformation.
        let legacy = calculate_projection(&base_req());
        let mx = calculate_projection(&mx_req());
        assert!(
            (mx.fire_metrics.fi_number - legacy.fire_metrics.fi_number).abs() < 1e-6,
            "identity broken: {} vs {}",
            mx.fire_metrics.fi_number,
            legacy.fire_metrics.fi_number
        );
        assert_eq!(
            mx.monte_carlo.success_rate,
            legacy.monte_carlo.success_rate
        );
        assert!(
            (mx.points.last().unwrap().balance - legacy.points.last().unwrap().balance).abs()
                < 1e-6
        );
        let block = mx.mx_scenario.expect("mx block present");
        assert!((block.effective_annual_expenses_usd - 40_000.0).abs() < 1e-6);
        assert!((block.fx_rate_at_retirement - 20.0).abs() < 1e-9);
        // Dual-currency restatement: MXN figures are USD × the rate.
        assert!((block.fi_number_mxn - block.fi_number_usd * 20.0).abs() < 1e-6);
        assert!(
            (block.monthly_income_at_retirement_mxn
                - block.monthly_income_at_retirement_usd * 20.0)
                .abs()
                < 1e-6
        );
    }

    #[test]
    fn mx_peso_weakening_drift_lowers_the_fi_number() {
        // +3%/yr drift over 20 accumulation years: the peso spending costs
        // fewer real dollars at retirement, so the FI number drops below the
        // zero-drift $1M — by exactly the compounded rate.
        let mut req = mx_req();
        req.fx_annual_drift = Some(0.03);
        let res = calculate_projection(&req);
        let block = res.mx_scenario.expect("mx block present");
        let expected_rate = 20.0 * 1.03_f64.powi(20);
        assert!((block.fx_rate_at_retirement - expected_rate).abs() < 1e-6);
        let expected_fi = (800_000.0 / expected_rate) / 0.04;
        assert!(
            (res.fire_metrics.fi_number - expected_fi).abs() < 1e-6,
            "got {}, expected {expected_fi}",
            res.fire_metrics.fi_number
        );
        assert!(res.fire_metrics.fi_number < 1_000_000.0);
        // A strengthening peso (negative drift) moves it the other way.
        req.fx_annual_drift = Some(-0.03);
        let stronger = calculate_projection(&req);
        assert!(stronger.fire_metrics.fi_number > 1_000_000.0);
    }

    #[test]
    fn mx_mixed_split_sums_per_currency() {
        // $20k USD + 400k MXN at rate 20, 0 drift → 20k + 20k = $40k.
        let mut req = mx_req();
        req.annual_expenses_usd_portion = Some(20_000.0);
        req.annual_expenses_mxn_portion = Some(400_000.0);
        let res = calculate_projection(&req);
        assert!((res.fire_metrics.fi_number - 1_000_000.0).abs() < 1e-6);
    }

    #[test]
    fn mx_inputs_are_clamped_and_rate_falls_back() {
        // Absurd drift clamps to +10%/yr; a missing/zero rate falls back to
        // the house 20.0; garbage portions clamp to 0 instead of poisoning
        // the whole projection with NaN/inf.
        let mut req = mx_req();
        req.fx_annual_drift = Some(5.0); // "500%/yr"
        req.usd_mxn_rate = None;
        let res = calculate_projection(&req);
        let block = res.mx_scenario.expect("mx block present");
        assert!((block.fx_annual_drift - 0.10).abs() < 1e-12);
        assert!((block.fx_rate_today - 20.0).abs() < 1e-12);

        let mut req = mx_req();
        req.annual_expenses_usd_portion = Some(f64::NAN);
        req.annual_expenses_mxn_portion = Some(f64::INFINITY);
        let res = calculate_projection(&req);
        let block = res.mx_scenario.expect("mx block present");
        // Non-finite garbage (NaN/inf) is treated as "not provided" → 0.
        assert_eq!(block.annual_expenses_usd_portion, 0.0);
        assert_eq!(block.annual_expenses_mxn_portion, 0.0);
        assert!(res.fire_metrics.fi_number.is_finite());
        // A finite-but-absurd portion clamps to the 1e12 cap instead.
        let mut req = mx_req();
        req.annual_expenses_mxn_portion = Some(1e30);
        let res = calculate_projection(&req);
        let block = res.mx_scenario.expect("mx block present");
        assert_eq!(block.annual_expenses_mxn_portion, 1e12);
        assert!(res.fire_metrics.fi_number.is_finite());
    }

    #[test]
    fn years_to_fi_zero_when_already_past_target() {
        let mut req = base_req();
        req.start_balance = 2_000_000.0;
        let res = calculate_projection(&req);
        assert_eq!(res.fire_metrics.estimated_years_to_fi, Some(0.0));
    }
}
