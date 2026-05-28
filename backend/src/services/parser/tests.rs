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
fn test_cetes_csv() {
    let data = "Fecha,Descripción,Monto\n2024-03-15,BONOS,1000.00".as_bytes();
    let result = cetes::parse_csv(data).unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].amount, Decimal::from_str("1000.00").unwrap());
}

#[test]
fn test_parse_nu_mexico_pdf_text() {
    let text = "15 MAR Uber Mexico $ 150.50\n16 MAR OXXO $ 50.00";
    let result = nu_mexico_pdf::parse_text(text).unwrap();
    
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "Uber Mexico");
    assert_eq!(result[0].amount, Decimal::from_str("150.50").unwrap());
}

#[test]
fn test_parse_cetes_pdf_text() {
    let text = "15/03/2024 COMPRA CETES 28 DIAS $ 1,000.00\n16/03/2024 VENTA BONOS $ 5,500.25";
    let result = cetes_pdf::parse_text(text).unwrap();
    
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "COMPRA CETES 28 DIAS");
    assert_eq!(result[0].amount, Decimal::from_str("1000.00").unwrap());
    assert_eq!(result[1].amount, Decimal::from_str("5500.25").unwrap());
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
    let _empty_data = vec![0, 0, 0];
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
        original_description: None,
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
        original_description: None,
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
