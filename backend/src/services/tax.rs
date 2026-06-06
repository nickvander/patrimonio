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

#[derive(Debug, Serialize, Deserialize)]
pub struct TaxEstimation {
    #[serde(with = "rust_decimal::serde::float")]
    pub ordinary_income: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub capital_gains: Decimal,
    /// Short-term realized gains (held <= 1 year) — taxed as ordinary income.
    #[serde(with = "rust_decimal::serde::float")]
    pub short_term_gains: Decimal,
    /// Long-term realized gains (held > 1 year) — preferential LTCG rates.
    #[serde(with = "rust_decimal::serde::float")]
    pub long_term_gains: Decimal,
    /// True when the gains came from precise lot-disposal records rather than
    /// the blended cost-basis fallback.
    pub gains_from_lots: bool,
    #[serde(with = "rust_decimal::serde::float")]
    pub total_taxable: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub estimated_liability_us: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub estimated_liability_mx: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub effective_rate_us: Decimal,
    #[serde(with = "rust_decimal::serde::float")]
    pub effective_rate_mx: Decimal,
}

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

        // 1. Calculate Ordinary Income (Sum of Salary/Income transactions) — scoped to user.
        let income_row = sqlx::query(
            r#"
            SELECT COALESCE(SUM(amount), 0) as total_income
            FROM transactions
            WHERE date >= $1 AND date <= $2
            AND amount > 0
            AND (category = 'Income' OR category = 'Salary' OR category = 'Interest')
            AND user_id = $3
            "#
        )
        .bind(start_date)
        .bind(end_date)
        .bind(user_id)
        .fetch_one(db)
        .await?;

        let ordinary_income: Decimal = income_row.try_get("total_income").unwrap_or_default();

        // 2. Realized capital gains. Prefer PRECISE lot disposals (actual P&L
        //    with holding periods) and split short- vs long-term; fall back to
        //    the blended cost-basis estimate when no lot data exists.
        let disp = sqlx::query(
            r#"
            SELECT
                COALESCE(SUM(CASE WHEN l.acquired_at IS NOT NULL
                                   AND (d.sell_date - l.acquired_at) <= 365
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS short_term,
                -- Long-term: held > 1 year, OR holding period unknown (the
                -- source lot was deleted) — most brokerage lots are long-term,
                -- so this is the conservative default.
                COALESCE(SUM(CASE WHEN l.acquired_at IS NULL
                                   OR (d.sell_date - l.acquired_at) > 365
                              THEN d.realized_pnl_usd ELSE 0 END), 0) AS long_term,
                COUNT(*) AS n
            FROM lot_disposals d
            LEFT JOIN holding_lots l ON l.id = d.lot_id
            WHERE d.user_id = $1
              AND EXTRACT(YEAR FROM d.sell_date)::int = $2
            "#,
        )
        .bind(user_id)
        .bind(year)
        .fetch_one(db)
        .await?;

        let disposal_count: i64 = disp.try_get("n").unwrap_or(0);
        let gains_from_lots = disposal_count > 0;

        let (short_term_gains, long_term_gains) = if gains_from_lots {
            (
                disp.try_get::<Decimal, _>("short_term").unwrap_or_default(),
                disp.try_get::<Decimal, _>("long_term").unwrap_or_default(),
            )
        } else {
            // Fallback: blended cost-basis estimate from "Investment Sale" rows,
            // treated as long-term (the prior behaviour).
            let basis_row = sqlx::query(
                r#"
                SELECT COALESCE(SUM(cost_basis), 0) as total_basis, COALESCE(SUM(value), 0) as total_value
                FROM holdings
                WHERE value > 0 AND cost_basis IS NOT NULL AND user_id = $1
                "#,
            )
            .bind(user_id)
            .fetch_one(db)
            .await?;
            let total_basis: Decimal = basis_row.try_get("total_basis").unwrap_or_default();
            let total_value: Decimal = basis_row.try_get("total_value").unwrap_or_default();
            let mut cost_basis_ratio = dec!(0.8);
            if total_value > dec!(0) {
                let actual_ratio = total_basis / total_value;
                if actual_ratio > dec!(0) && actual_ratio <= dec!(1) {
                    cost_basis_ratio = actual_ratio;
                }
            }
            let gains_row = sqlx::query(
                r#"
                SELECT COALESCE(SUM(amount), 0) as total_gains
                FROM transactions
                WHERE date >= $1 AND date <= $2
                AND amount > 0
                AND category = 'Investment Sale'
                AND user_id = $3
                "#,
            )
            .bind(start_date)
            .bind(end_date)
            .bind(user_id)
            .fetch_one(db)
            .await?;
            let sale_proceeds: Decimal = gains_row.try_get("total_gains").unwrap_or_default();
            (dec!(0), sale_proceeds * (dec!(1) - cost_basis_ratio))
        };

        let capital_gains = short_term_gains + long_term_gains;

        // US: short-term gains stack onto ordinary income (ordinary brackets);
        // long-term gains get the preferential LTCG rates on top of that.
        let ordinary_taxable = ordinary_income + short_term_gains;
        let estimated_liability_us = Self::calculate_us_tax(ordinary_taxable, status)
            + Self::calculate_us_ltcg(long_term_gains, ordinary_taxable, status);

        // MX: no preferential split here — everything flows through the ISR
        // brackets (a deliberate simplification).
        let total_taxable = ordinary_income + capital_gains;
        let estimated_liability_mx = Self::calculate_mx_tax(total_taxable);

        let effective_rate_us = if total_taxable > dec!(0) { estimated_liability_us / total_taxable } else { dec!(0) };
        let effective_rate_mx = if total_taxable > dec!(0) { estimated_liability_mx / total_taxable } else { dec!(0) };

        Ok(TaxEstimation {
            ordinary_income,
            capital_gains,
            short_term_gains,
            long_term_gains,
            gains_from_lots,
            total_taxable,
            estimated_liability_us,
            estimated_liability_mx,
            effective_rate_us,
            effective_rate_mx,
        })
    }

    pub async fn get_taxable_transactions(
        db: &PgPool,
        year: i32,
        user_id: uuid::Uuid,
    ) -> Result<Vec<crate::models::transaction::Transaction>> {
        let start_date = chrono::NaiveDate::from_ymd_opt(year, 1, 1).unwrap();
        let end_date = chrono::NaiveDate::from_ymd_opt(year, 12, 31).unwrap();

        let rows = sqlx::query_as::<_, crate::models::transaction::Transaction>(
            r#"
            SELECT *
            FROM transactions
            WHERE date >= $1 AND date <= $2
            AND amount > 0
            AND (category = 'Income' OR category = 'Salary' OR category = 'Interest' OR category = 'Investment Sale')
            AND user_id = $3
            ORDER BY date DESC
            "#
        )
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
                   (d.sell_date - l.acquired_at) AS holding_days
            FROM lot_disposals d
            JOIN holdings h ON h.id = d.holding_id
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
                }
            })
            .collect())
    }
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
    fn ltcg_ignores_losses() {
        assert_eq!(
            TaxService::calculate_us_ltcg(dec!(-5000), dec!(50000), "Single"),
            dec!(0)
        );
    }
}
