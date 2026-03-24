use super::*;
use rust_decimal::Decimal;
use std::str::FromStr;
use chrono::NaiveDate;

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
    let result = detect_and_parse("banamex_statement.csv", data).unwrap();
    assert_eq!(result.len(), 1);
    
    // Should route to Nu
    let nu_data = "Fecha,Descripción,Monto\n2024-03-15,Test,-10.0".as_bytes();
    let result = detect_and_parse("nu_mexico.csv", nu_data).unwrap();
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

#[test]
fn test_parse_banamex_pdf_text() {
    let text = "15 MAR COMPRA OXXO $ 50.00\n16 MAR DEPOSITO $ 1,200.50";
    let result = banamex_pdf::parse_text(text).unwrap();
    
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].description, "COMPRA OXXO");
    assert_eq!(result[0].amount, Decimal::from_str("-50.00").unwrap()); // Matches amount_str.replace(",", "") and Decimal::from_str
    assert_eq!(result[1].amount, Decimal::from_str("1200.50").unwrap());
}
