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

    pub async fn calculate_yearly_tax(db: &PgPool, year: i32, status: &str) -> Result<TaxEstimation> {
        let start_date = chrono::NaiveDate::from_ymd_opt(year, 1, 1).unwrap();
        let end_date = chrono::NaiveDate::from_ymd_opt(year, 12, 31).unwrap();

        // 1. Calculate Ordinary Income (Sum of Salary/Income transactions)
        let income_row = sqlx::query(
            r#"
            SELECT COALESCE(SUM(amount), 0) as total_income
            FROM transactions
            WHERE date >= $1 AND date <= $2
            AND amount > 0
            AND (category = 'Income' OR category = 'Salary' OR category = 'Interest')
            "#
        )
        .bind(start_date)
        .bind(end_date)
        .fetch_one(db)
        .await?;

        let ordinary_income: Decimal = income_row.try_get("total_income").unwrap_or_default();

        // 2. Realized Capital Gains (Blended Cost Basis Approach)
        // Scalable generic approach: Determine the overall portfolio cost basis ratio
        // from the `holdings` table, and apply that ratio globally to sale proceeds.
        let basis_row = sqlx::query(
            r#"
            SELECT COALESCE(SUM(cost_basis), 0) as total_basis, COALESCE(SUM(value), 0) as total_value
            FROM holdings
            WHERE value > 0 AND cost_basis IS NOT NULL
            "#
        )
        .fetch_one(db)
        .await?;

        let total_basis: Decimal = basis_row.try_get("total_basis").unwrap_or_default();
        let total_value: Decimal = basis_row.try_get("total_value").unwrap_or_default();
        
        let mut cost_basis_ratio = dec!(0.8); // fallback conservative 80% basis (20% gains)
        if total_value > dec!(0) {
            let actual_ratio = total_basis / total_value;
            // Prevent nonsense ratios (e.g., basis > value or negative)
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
            "#
        )
        .bind(start_date)
        .bind(end_date)
        .fetch_one(db)
        .await?;
        
        let sale_proceeds: Decimal = gains_row.try_get("total_gains").unwrap_or_default();
        
        // Capital gains = Proceeds - estimated Cost Basis mapped to those proceeds
        let capital_gains = sale_proceeds * (dec!(1) - cost_basis_ratio);

        let total_taxable = ordinary_income + capital_gains;

        let estimated_liability_us = Self::calculate_us_tax(total_taxable, status);
        let estimated_liability_mx = Self::calculate_mx_tax(total_taxable);

        let effective_rate_us = if total_taxable > dec!(0) { estimated_liability_us / total_taxable } else { dec!(0) };
        let effective_rate_mx = if total_taxable > dec!(0) { estimated_liability_mx / total_taxable } else { dec!(0) };

        Ok(TaxEstimation {
            ordinary_income,
            capital_gains,
            total_taxable,
            estimated_liability_us,
            estimated_liability_mx,
            effective_rate_us,
            effective_rate_mx,
        })
    }

    pub async fn get_taxable_transactions(db: &PgPool, year: i32) -> Result<Vec<crate::models::transaction::Transaction>> {
         let start_date = chrono::NaiveDate::from_ymd_opt(year, 1, 1).unwrap();
         let end_date = chrono::NaiveDate::from_ymd_opt(year, 12, 31).unwrap();

         let rows = sqlx::query_as::<_, crate::models::transaction::Transaction>(
             r#"
             SELECT *
             FROM transactions
             WHERE date >= $1 AND date <= $2
             AND amount > 0
             AND (category = 'Income' OR category = 'Salary' OR category = 'Interest' OR category = 'Investment Sale')
             ORDER BY date DESC
             "#
         )
         .bind(start_date)
         .bind(end_date)
         .fetch_all(db)
         .await?;

         Ok(rows)
    }
}
