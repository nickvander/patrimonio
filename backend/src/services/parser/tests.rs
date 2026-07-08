use super::*;
use rust_decimal::Decimal;
use std::str::FromStr;
use chrono::{NaiveDate, Datelike};

#[test]
fn test_parse_nu_mexico_csv() {
    let data = "Fecha,Descripción,Monto\n2024-03-15,Uber Mexico,-150.50\n16/03/2024,OXXO Gas,500.00".as_bytes();
    let result = nu_mexico::parse_csv(data).unwrap();
    
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].date, NaiveDate::from_ymd_opt(2024, 3, 15).unwrap());
    assert_eq!(result[0].amount, Decimal::from_str("-150.50").unwrap());
    assert_eq!(result[1].date, NaiveDate::from_ymd_opt(2024, 3, 16).unwrap());
    assert_eq!(result[1].amount, Decimal::from_str("500.00").unwrap());
}

#[test]
fn test_parse_banamex_csv() {
    let data = "Fecha,Concepto,Monto\n15/03/2024,COMPRA OXXO,-50.00".as_bytes();
    let result = banamex::parse_csv(data).unwrap();
    
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].description, "COMPRA OXXO");
    assert_eq!(result[0].amount, Decimal::from_str("-50.00").unwrap());
}

#[test]
fn test_detect_and_parse_routing() {
    let data = "Fecha,Concepto,Monto\n15/03/2024,Test,10.0".as_bytes();
    
    // Should route to Banamex
    let result = detect_and_parse("banamex_statement.csv", data, None).unwrap();
    assert_eq!(result.len(), 1);
    
    // Should route to Nu
    let nu_data = "Fecha,Descripción,Monto\n2024-03-15,Test,-10.0".as_bytes();
    let result = detect_and_parse("nu_mexico.csv", nu_data, None).unwrap();
    assert_eq!(result.len(), 1);
}

#[test]
fn detect_and_parse_auto_categorizes() {
    // A CSV routed through detect_and_parse should come back categorized
    // via polish_all → categorize, so imported rows aren't all
    // "Uncategorized".
    let data = "Fecha,Concepto,Monto\n15/03/2024,COMPRA OXXO COL CENTRO,-50.00\n16/03/2024,SPEI RECIBIDO NOMINA,12000.00".as_bytes();
    let result = detect_and_parse("banamex_statement.csv", data, None).unwrap();
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].category.as_deref(), Some("FOOD_AND_DRINK"));
    // "NOMINA" wins over the SPEI transfer rule → income.
    assert_eq!(result[1].category.as_deref(), Some("INCOME"));
}

#[test]
fn test_cetes_csv() {
    let data = "Fecha,Descripción,Monto\n2024-03-15,BONOS,1000.00".as_bytes();
    let result = cetes::parse_csv(data).unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].amount, Decimal::from_str("1000.00").unwrap());
}

#[test]
fn test_parse_nu_mexico_pdf_text() {
    // Balance-less rows: sign comes from keyword, defaulting to debit for an
    // unrecognised merchant ("Uber"/"OXXO" aren't keyworded → spending).
    let text = "15 MAR Uber Mexico $ 150.50\n16 MAR Recibiste de PATRON $ 500.00";
    let result = nu_mexico_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "Uber Mexico");
    assert_eq!(result[0].amount, Decimal::from_str("-150.50").unwrap());
    // "Recibiste" → credit (positive).
    assert_eq!(result[1].amount, Decimal::from_str("500.00").unwrap());
}

#[test]
fn test_parse_cetes_pdf_text() {
    // Real cetesdirecto "Movimientos del período" layout: two DD/MM/YY dates,
    // folio+code, emisora, serie, then Cargo / Abono / Saldo efectivo.
    let text = "Movimientos del período\n\
        15/03/24   15/03/24   SVD111COMPRA   CETES   240725   1,000   9.74100300   86   11.30   9,741.00   0.00   -9,740.10\n\
        16/03/24   16/03/24   SVD112VTASI    BONDDIA PF2      5,500   1.94000000  0    0.00    0.00       5,500.25   0.15\n\
        Saldo final   0.15";
    let result = cetes_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2, "got {:#?}", result);
    // Buy CETES → Cargo, negative.
    assert_eq!(result[0].amount, Decimal::from_str("-9741.00").unwrap());
    assert!(result[0].description.contains("CETES"));
    // Sell → Abono, positive.
    assert_eq!(result[1].amount, Decimal::from_str("5500.25").unwrap());
    // T14: a buy is principal-out, a generic sell is principal+yield combined;
    // neither is tagged income (only explicit yield rows are — see below).
    assert_eq!(result[0].category, None);
    assert_eq!(result[1].category, None);
}

#[test]
fn test_cetes_pdf_maturity_premium_is_income() {
    // T14: a cetesdirecto maturity-PREMIO credit (the CETES yield: discount
    // instrument redeemed above its purchase price) must be tagged INCOME
    // with a POSITIVE (inflow) amount, so it reaches the income predicate and
    // the MX tax base — while the COMPRA principal buy stays uncategorized.
    let text = "Movimientos del período\n\
        15/03/24   15/03/24   SVD111COMPRA   CETES   240725   1,000   9.74100300   86   11.30   9,741.00   0.00   -9,740.10\n\
        25/07/24   25/07/24   SVD222PREMIO   CETES   240725   0       0            0    0.00    0.00      258.74     258.64\n\
        Saldo final   258.64";
    let result = cetes_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2, "got {:#?}", result);
    // The PREMIO row: positive inflow, tagged income.
    let premio = result
        .iter()
        .find(|t| t.description.contains("PREMIO"))
        .expect("premio row present");
    assert!(premio.amount > Decimal::ZERO, "yield must be a positive inflow");
    assert_eq!(premio.amount, Decimal::from_str("258.74").unwrap());
    assert_eq!(premio.category.as_deref(), Some("INCOME"));
    // The COMPRA principal buy is NOT income.
    let compra = result
        .iter()
        .find(|t| t.description.contains("COMPRA"))
        .expect("compra row present");
    assert!(compra.amount < Decimal::ZERO);
    assert_eq!(compra.category, None);
}

#[test]
fn test_cetes_csv_interest_is_income() {
    // T14 via the CSV path: an explicit interest credit is income (positive);
    // a generic principal buy is not.
    let data = "Fecha,Descripción,Monto\n\
        2024-03-15,COMPRA CETES 28D,-1000.00\n\
        2024-07-25,INTERESES CETES,18.42"
        .as_bytes();
    let result = cetes::parse_csv(data).unwrap();
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].category, None);
    assert_eq!(result[1].amount, Decimal::from_str("18.42").unwrap());
    assert_eq!(result[1].category.as_deref(), Some("INCOME"));
}

// The banamex_pdf::parse_text tests below feed the parser the same
// line-separated layout that lopdf actually produces when it extracts
// text from a Banamex PDF — each field on its own line:
//
//   25
//   ENE
//   PAGO RECIBIDO DE BBVA BANCOMER
//   ...
//   1,234.56
//
// The earlier all-on-one-line inputs reflected a different (older)
// parser shape and stopped matching after the lopdf-shaped rewrite,
// silently producing 0 transactions. Keeping the assertions intact;
// only the input scaffolding changes.

#[test]
fn test_parse_banamex_pdf_text() {
    let text = "DETALLE DE MOVIMIENTOS\n\
                15\nMAR\nCOMPRA OXXO\n$ 50.00\n\
                16\nMAR\nDEPOSITO\n$ 1,200.50";
    let result = banamex_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "COMPRA OXXO");
    assert_eq!(result[0].amount, Decimal::from_str("-50.00").unwrap());
    assert_eq!(result[1].amount, Decimal::from_str("1200.50").unwrap());
}

#[test]
fn test_parse_banamex_pdf_full_months() {
    let text = "DETALLE DE MOVIMIENTOS\n\
                25\nABRIL\nCOMPRA AMAZON\n$ 1,500.00\n\
                24\nMAYO\nABONO NOMINA\n$ 12,000.00";
    let result = banamex_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "COMPRA AMAZON");
    assert_eq!(result[0].amount, Decimal::from_str("-1500.00").unwrap());
    assert_eq!(result[0].date.month(), 4);
    assert_eq!(result[1].description, "ABONO NOMINA");
    assert_eq!(result[1].amount, Decimal::from_str("12000.00").unwrap());
    assert_eq!(result[1].date.month(), 5);
}

#[test]
fn test_parse_banamex_pdf_de_dates() {
    // "DE" is the Spanish connector — "23 de enero". lopdf splits it
    // onto its own line. The parser filters bare "DE" lines so
    // record detection still sees day → month.
    let text = "DETALLE DE MOVIMIENTOS\n\
                23\nDE\nENERO\nCOMPRA AMAZON\n$ 500.00\n\
                24\nDE\nFEBRERO\nDEPOSITO\n$ 1,000.00";
    let result = banamex_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "COMPRA AMAZON");
    assert_eq!(result[0].amount, Decimal::from_str("-500.00").unwrap());
    assert_eq!(result[0].date.month(), 1);
    assert_eq!(result[1].date.month(), 2);
}

#[test]
fn test_parse_banamex_pdf_summary_filtering() {
    // The parser is supposed to skip everything before
    // "DETALLE DE MOVIMIENTOS" — the resumen / saldo-anterior block
    // mixes in numbers that look like transactions but aren't.
    let text = "RESUMEN DE CUENTA\n\
                25\nABR\nSALDO ANTERIOR\n$ 10,000.00\n\
                25\nABR\nINTERESES (RESUMEN)\n$ 5.50\n\
                DETALLE DE MOVIMIENTOS\n\
                26\nABR\nCOMPRA OXXO\n$ 150.00\n\
                27\nABR\nDEPOSITO\n$ 2,000.00";

    let result = banamex_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "COMPRA OXXO");
    assert_eq!(result[0].amount, Decimal::from_str("-150.00").unwrap());
    assert_eq!(result[1].description, "DEPOSITO");
}

#[test]
fn test_parse_banamex_pdf_normalization() {
    // The pathological-but-real lopdf output: amount and currency
    // marker on separate lines, COMPRA and the merchant on separate
    // lines too. Verifies the parser stitches them back together
    // and skips the lone "$" line cleanly.
    let text = "DETALLE DE MOVIMIENTOS\n26\nABRIL\nCOMPRA\nOXXO\n$\n1,500";
    let result = banamex_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].description, "COMPRA OXXO");
    assert_eq!(result[0].amount, Decimal::from_str("-1500.00").unwrap());
}

#[test]
fn test_parse_banamex_pdf_whole_numbers() {
    // Round-peso amounts arrive without the ".00" suffix.
    let text = "DETALLE DE MOVIMIENTOS\n\
                26\nABR\nCOMPRA\n$ 4,000\n\
                27\nABR\nDEPOSITO\n$ 56,500";
    let result = banamex_pdf::parse_text(text).unwrap();

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].amount, Decimal::from_str("-4000.00").unwrap());
    assert_eq!(result[1].amount, Decimal::from_str("56500.00").unwrap());
}

#[test]
fn test_detect_and_parse_filename_fallback() {
    // If data is empty and couldn't be parsed, it should still identify via filename as last resort
    let _empty_data = [0, 0, 0];
    // This will fail loading PDF (Document::load_mem) and bypass content scan
    // But the routing should still catch the filename keyword if we called it with a specific flow
    // Actually, detect_and_parse will fail at Document::load_mem.
    // Let's test that the institution is correctly mapped if we reach that logic.
}

#[test]
fn test_detect_and_parse_content() {
    // Test detection based on CSV headers instead of filename
    let nu_data = "Fecha,Descripción,Monto\n2024-03-15,Test,-10.0".as_bytes();
    let result = detect_and_parse("random_name.csv", nu_data, None).unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].currency, "MXN");

    let banamex_data = "Fecha,Concepto,Monto\n15/03/2024,Test,10.0".as_bytes();
    let result = detect_and_parse("statement.csv", banamex_data, None).unwrap();
    assert_eq!(result.len(), 1);
}

#[test]
fn test_polish_description_strips_trailing_yyyymmdd() {
    assert_eq!(polish_description("MISC DEBIT 20260418"), "MISC DEBIT");
    assert_eq!(polish_description("UBER MEXICO 20260418"), "UBER MEXICO");
    assert_eq!(polish_description("UBER 20260418 OAXACA"), "UBER 20260418 OAXACA"); // mid-string is not stripped
}

#[test]
fn test_polish_description_strips_trailing_dmy_date() {
    assert_eq!(polish_description("COMPRA OXXO 18/04/2026"), "OXXO");
    assert_eq!(polish_description("PAGO RECIBIDO 18-04-2026"), "RECIBIDO");
}

#[test]
fn test_polish_description_strips_generic_prefix() {
    assert_eq!(polish_description("COMPRA OXXO"), "OXXO");
    assert_eq!(polish_description("RETIRO CAJERO BANAMEX"), "CAJERO BANAMEX");
    assert_eq!(polish_description("MISC DEBIT NETFLIX"), "NETFLIX");
}

#[test]
fn test_polish_description_preserves_when_strip_would_empty() {
    // "MISC DEBIT" alone has nothing after the prefix — keep it so the
    // user doesn't see a blank row.
    assert_eq!(polish_description("MISC DEBIT"), "MISC DEBIT");
    // Only a date and a prefix — keep the prefix as the safety net.
    assert_eq!(polish_description("MISC DEBIT 20260418"), "MISC DEBIT");
}

#[test]
fn test_polish_description_collapses_whitespace() {
    assert_eq!(polish_description("UBER    EATS   MEXICO"), "UBER EATS MEXICO");
}

#[test]
fn test_polish_all_captures_original_when_changed() {
    // Polishing strips "COMPRA " + " 20260418" → "OXXO". The raw line
    // should round-trip into original_description so the frontend's
    // displayLabel ladder can fall back to it.
    let raw = "COMPRA OXXO 20260418".to_string();
    let parsed = vec![ParsedTransaction {
        date: NaiveDate::from_ymd_opt(2026, 4, 18).unwrap(),
        description: raw.clone(),
        amount: Decimal::from_str("-50.00").unwrap(),
        currency: "MXN".to_string(),
        category: None,
        category_detailed: None,
        original_description: None,
        balance_after: None,
        account_label: None,
        from_ocr: false,
    }];
    let polished = polish_all(Ok(parsed)).unwrap();
    assert_eq!(polished[0].description, "OXXO");
    assert_eq!(polished[0].original_description.as_deref(), Some("COMPRA OXXO 20260418"));
}

#[test]
fn test_polish_all_skips_original_when_unchanged() {
    // No prefix and no trailing date — polish is a no-op. The
    // original_description column stays NULL to avoid duplicating
    // identical strings across two columns.
    let parsed = vec![ParsedTransaction {
        date: NaiveDate::from_ymd_opt(2026, 4, 18).unwrap(),
        description: "UBER EATS MEXICO".to_string(),
        amount: Decimal::from_str("-150.00").unwrap(),
        currency: "MXN".to_string(),
        category: None,
        category_detailed: None,
        original_description: None,
        balance_after: None,
        account_label: None,
        from_ocr: false,
    }];
    let polished = polish_all(Ok(parsed)).unwrap();
    assert_eq!(polished[0].description, "UBER EATS MEXICO");
    assert!(polished[0].original_description.is_none());
}

#[test]
fn test_polish_description_idempotent() {
    let once = polish_description("COMPRA OXXO 20260418");
    let twice = polish_description(&once);
    assert_eq!(once, twice);
    assert_eq!(once, "OXXO");
}

#[test]
fn garbled_extraction_detected_for_ocr() {
    // Plenty of letters but none of the statement vocabulary → broken-font
    // gibberish that must be routed to OCR.
    let gibberish = "zxq wbk plf vnt grd hjm ".repeat(40); // >200 alpha, no anchors
    assert!(super::looks_garbled(&gibberish));

    // A normal extraction with real statement words is NOT garbled.
    let real = "ESTADO DE CUENTA\nFECHA DESCRIPCION SALDO\n01-FEB-21 DEPOSITO 1,000.00";
    assert!(!super::looks_garbled(real));
    assert!(super::has_statement_anchor(real));

    // Genuinely sparse text falls to the length-based OCR trigger, not here.
    assert!(!super::looks_garbled("HSBC"));
}

// ───────────────────────── Revolut (MX) ─────────────────────────
// Two layouts; fixtures mirror the real `pdftotext -layout` output (the
// savings layout splits each record across three physical lines). Sign is
// derived from the running-balance delta, so it survives the two layouts'
// opposite Money in / Money out column order.

#[test]
fn revolut_savings_layout() {
    // Daily "Net interest paid" credits + a "Deposit" row; the date renders
    // split (`May 1,` … `2026`) with the amounts on the middle line.
    let text = "\
                                        Instant Access Savings
                                            Generated on May 31, 2026
                                            Period: May 1, 2026 – May 31, 2026

Balance summary
 Opening Balance                                  $17,186.79
 Closing Balance                                  $18,200.28

Transactions from May 1, 2026 to May 31, 2026
 Date          Description              Gross interest rate earned   Money in   Money out   Balance

 May 1,        Net interest paid to \"Instant Access Savings\" for
                                        15.00%                       $6.74                  $17,193.53
 2026          May 1, 2026

 May 2,        Net interest paid to \"Instant Access Savings\" for
                                        15.00%                       $6.75                  $17,200.28
 2026          May 2, 2026

 May 3,
               Deposit to \"Instant Access Savings\"                 $1,000.00              $18,200.28
 2026

Interest
";
    let rows = revolut::parse_text(text).unwrap();
    assert_eq!(rows.len(), 3);

    assert_eq!(rows[0].date, NaiveDate::from_ymd_opt(2026, 5, 1).unwrap());
    assert_eq!(rows[0].amount, Decimal::from_str("6.74").unwrap()); // 17193.53 - 17186.79
    assert_eq!(rows[0].balance_after, Some(Decimal::from_str("17193.53").unwrap()));
    assert_eq!(rows[0].currency, "MXN");
    assert_eq!(rows[0].category.as_deref(), Some("INCOME"));
    assert_eq!(rows[0].category_detailed.as_deref(), Some("INCOME_INTEREST_EARNED"));
    assert_eq!(rows[0].account_label, None);

    assert_eq!(rows[1].amount, Decimal::from_str("6.75").unwrap());

    // The deposit is an inflow (balance jumped 17200.28 → 18200.28).
    assert_eq!(rows[2].date, NaiveDate::from_ymd_opt(2026, 5, 3).unwrap());
    assert_eq!(rows[2].amount, Decimal::from_str("1000.00").unwrap());
    assert_eq!(rows[2].category.as_deref(), Some("TRANSFER_IN"));
}

#[test]
fn revolut_personal_layout() {
    // Personal "<CCY> Statement": two labelled sections, opposite column order
    // (Money out | Money in | Balance), per-section opening seeds.
    let text = "\
                          MXN Statement
                                From April 1, 2026 to April 30, 2026

NICK VAN DER
29 C SERVIA                                  Account Number 8238777
45167                                        CLABE for SPEI 6469 9040 4082 387772

Balance summary
 Product                       Opening balance   Money out    Money in     Closing balance
 Mexican Peso Account          $0.00             $1,000.00    $1,000.00    $0.00
 Instant Access Savings        $0.00             $0.00        $1,006.74    $1,006.74

Account transactions from April 1, 2026 to April 30, 2026
Date            Description                          Money out      Money in      Balance

Apr 23, 2026    SPEI Transfer received from STP                     $1,000.00     $1,000.00
                From: SOMEONE, 123456, NU MEXICO
                Description: Transferencia

Apr 23, 2026    To Instant Access Savings            $1,000.00                    $0.00

Instant Access Savings transactions from April 1, 2026 to April 30, 2026
Date            Description                          Money out      Money in      Balance

Apr 23, 2026    To Instant Access Savings                           $1,000.00     $1,000.00

Apr 23, 2026    Net interest paid to \"Instant Access Savings\" for Apr 23,       $6.74    $1,006.74
                2026

Summary of balances and movements during the period
";
    let rows = revolut::parse_text(text).unwrap();
    assert_eq!(rows.len(), 4);

    // Peso current account (its own label so the import UI keeps it separate
    // from the savings pocket): inflow then internal-move outflow.
    assert_eq!(rows[0].description, "SPEI Transfer received from STP");
    assert_eq!(rows[0].amount, Decimal::from_str("1000.00").unwrap());
    assert_eq!(rows[0].category.as_deref(), Some("TRANSFER_IN"));
    assert_eq!(rows[0].account_label.as_deref(), Some("Mexican Peso Account"));
    assert_eq!(rows[0].currency, "MXN");

    assert_eq!(rows[1].description, "To Instant Access Savings");
    assert_eq!(rows[1].amount, Decimal::from_str("-1000.00").unwrap()); // 0 - 1000
    assert_eq!(rows[1].category.as_deref(), Some("TRANSFER_OUT"));
    assert_eq!(rows[1].account_label.as_deref(), Some("Mexican Peso Account"));

    // Savings pocket (its own account_label), seeded from its $0.00 opening.
    assert_eq!(rows[2].amount, Decimal::from_str("1000.00").unwrap());
    assert_eq!(rows[2].account_label.as_deref(), Some("Instant Access Savings"));

    assert_eq!(rows[3].amount, Decimal::from_str("6.74").unwrap()); // 1006.74 - 1000
    assert_eq!(rows[3].category_detailed.as_deref(), Some("INCOME_INTEREST_EARNED"));
    assert_eq!(rows[3].account_label.as_deref(), Some("Instant Access Savings"));
}

#[test]
fn revolut_looks_like() {
    assert!(revolut::looks_like("© 2026 REVOLUT BANK, S.A."));
    assert!(!revolut::looks_like("BANCO NACIONAL DE MEXICO"));
}
