use crate::models::import::ParsedTransaction;
use anyhow::{Result, anyhow};
use csv::ReaderBuilder;
use rust_decimal::Decimal;
use chrono::NaiveDate;
use std::io::Cursor;

pub fn parse_csv(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let mut rdr = ReaderBuilder::new()
        .has_headers(true)
        .from_reader(Cursor::new(data));
    
    let mut transactions = Vec::new();
    
    for result in rdr.records() {
        let record = result.map_err(|e| anyhow!("CSV parse error: {e}"))?;
        
        // Cetesdirecto format (Mock): Fecha, Operación, Monto
        // 2024-03-15, COMPRA CETES 28D, 1000.00
        let date_str = record.get(0).ok_or_else(|| anyhow!("Missing date"))?.trim();
        let description = record.get(1).ok_or_else(|| anyhow!("Missing operation"))?.trim().to_string();
        let amount_str = record.get(2).ok_or_else(|| anyhow!("Missing amount"))?.trim();
        
        let date = NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
            .map_err(|_| anyhow!("Invalid date format: {date_str}"))?;
            
        let amount = amount_str.parse::<Decimal>()
            .map_err(|_| anyhow!("Invalid amount: {amount_str}"))?;

        // T14: tag explicit interest/maturity-premium credits as interest
        // income so CETES yield reaches the tax base AND itemizes in the
        // interest decomposition; ISR retentions get a withheld tag (a
        // non-income category) so the summary can total tax withheld;
        // principal movements (buys/redemptions/deposits) stay uncategorized.
        // `classify_cetes_movement` returns BOTH (category, category_detailed)
        // so this CSV parser and the PDF parser stay in sync.
        let (category, category_detailed) = match
            crate::services::categorize::classify_cetes_movement(&description, amount)
        {
            Some((c, d)) => (Some(c), d),
            None => (None, None),
        };

        transactions.push(ParsedTransaction {
            date,
            description,
            amount,
            currency: "MXN".to_string(),
            category,
            category_detailed,
            original_description: None,
            balance_after: None,
            account_label: None,
            from_ocr: false,
        });
    }

    Ok(transactions)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_tags_yield_interest_and_isr_withholding() {
        // Yield credit → interest income; ISR retention → withheld (non-income
        // category + detail); principal buy → an outgoing transfer (excluded
        // from income/spending), NOT uncategorized (a NULL row would count as
        // income in the cash-flow view).
        let csv = "Fecha,Operacion,Monto\n\
            2026-06-01,PREMIO CETES 260601,2000.00\n\
            2026-06-01,RETENCION ISR CETES,-200.00\n\
            2026-06-02,COMPRA CETES 261003,-5000.00\n";
        let txs = parse_csv(csv.as_bytes()).unwrap();
        assert_eq!(txs.len(), 3);

        assert_eq!(txs[0].category.as_deref(), Some("INCOME"));
        assert_eq!(txs[0].category_detailed.as_deref(), Some("INCOME_INTEREST_EARNED"));

        assert_eq!(txs[1].category.as_deref(), Some("GOVERNMENT_AND_NON_PROFIT"));
        assert_eq!(txs[1].category_detailed.as_deref(), Some("TAX_ISR_WITHHELD"));

        assert_eq!(txs[2].category.as_deref(), Some("TRANSFER_OUT"));
        assert_eq!(txs[2].category_detailed, None);
    }

    #[test]
    fn csv_tags_principal_redemptions_as_incoming_transfers() {
        // Fund redemption, principal amortization, and contract funding are all
        // principal movements → TRANSFER_IN (inflow), never income.
        let csv = "Fecha,Operacion,Monto\n\
            2026-06-03,VTASI BONDDIA,27000.00\n\
            2026-06-04,AMORTIZACION CETES 260604,29460.00\n\
            2026-06-05,INGEFVO,15000.00\n";
        let txs = parse_csv(csv.as_bytes()).unwrap();
        assert_eq!(txs.len(), 3);
        for t in &txs {
            assert_eq!(t.category.as_deref(), Some("TRANSFER_IN"),
                "principal inflow {:?} should be TRANSFER_IN", t.description);
            assert_eq!(t.category_detailed, None);
        }
    }
}
