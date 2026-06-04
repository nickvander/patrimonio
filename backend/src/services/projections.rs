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
    /// Optional RNG seed so tests are deterministic. Omit in production.
    #[serde(default)]
    pub mc_seed: Option<u64>,
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
    /// Year at which the accumulation phase ends. Clamped to the horizon.
    fn retire_year(&self) -> i32 {
        self.years_to_retirement.unwrap_or(self.years).clamp(0, self.years)
    }
    /// Real (inflation-adjusted) annual return via the Fisher relation.
    fn real_return(&self) -> f64 {
        real_return(self.annual_return_rate, self.inflation())
    }
}

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

#[derive(Debug, Serialize, Deserialize)]
pub struct ProjectionResponse {
    pub points: Vec<ProjectionPoint>,
    pub fire_metrics: FireMetrics,
    pub monte_carlo: MonteCarloResult,
    /// Always true today — all figures are in real (today's) dollars.
    pub real_dollars: bool,
}

/// Fisher relation: real = (1 + nominal) / (1 + inflation) - 1.
fn real_return(nominal: f64, inflation: f64) -> f64 {
    (1.0 + nominal) / (1.0 + inflation) - 1.0
}

/// Calculate a wealth projection in real (today's) dollars.
pub fn calculate_projection(req: &ProjectionRequest) -> ProjectionResponse {
    let real = req.real_return();
    let monthly_rate = (1.0 + real).powf(1.0 / 12.0) - 1.0;
    let retire_month = req.retire_year() * 12;
    let monthly_withdrawal = req.annual_expenses / 12.0;

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
    for m in 1..=(req.years * 12) {
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
    } else if retire_month >= req.years * 12 {
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

    ProjectionResponse {
        points,
        fire_metrics,
        monte_carlo,
        real_dollars: true,
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
    let horizon = req.years.max(0) as usize;
    let retire_year = req.retire_year();
    let sigma = req.volatility();
    let annual_contribution = req.monthly_contribution * 12.0;
    let annual_spend = req.annual_expenses;
    let drift = (1.0 + real).ln() - 0.5 * sigma * sigma;

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
        for y in 1..=horizon {
            let z = standard_normal(&mut rng);
            let growth = (drift + sigma * z).exp();
            if (y as i32) <= retire_year {
                bal = bal * growth + annual_contribution;
            } else {
                bal = bal * growth - annual_spend;
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
            mc_seed: Some(42),
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
    fn years_to_fi_zero_when_already_past_target() {
        let mut req = base_req();
        req.start_balance = 2_000_000.0;
        let res = calculate_projection(&req);
        assert_eq!(res.fire_metrics.estimated_years_to_fi, Some(0.0));
    }
}
