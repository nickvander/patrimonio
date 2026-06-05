// Dev tool: run a statement layout parser against a `pdftotext -layout` text
// file and print what it extracts. Used to validate the MX bank parsers
// against real statements.
//
//   cargo run --bin parse_check -- <banorte|scotiabank|hsbc|santander|bbva|banamex> <file.txt>

use patrimonio::services::parser::{
    banamex_layout, banorte_layout, bbva_layout, hsbc_layout, santander_layout, scotiabank_layout,
};
use std::env;
use std::fs;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: parse_check <bank> <file.txt>");
        std::process::exit(2);
    }
    let bank = args[1].to_lowercase();
    let path = &args[2];

    // A .pdf runs the FULL detect/extract/OCR pipeline (so we can validate the
    // garbled→OCR routing); a .txt runs one bank's layout parser directly.
    let txs = if path.to_lowercase().ends_with(".pdf") {
        let data = fs::read(path)?;
        patrimonio::services::parser::detect_and_parse(path, &data, None)?
    } else {
        let text = fs::read_to_string(path)?;
        match bank.as_str() {
            "banorte" => banorte_layout::parse_text(&text)?,
            "scotiabank" | "scotia" => scotiabank_layout::parse_text(&text)?,
            "hsbc" => hsbc_layout::parse_text(&text)?,
            "santander" => santander_layout::parse_text(&text)?,
            "bbva" => bbva_layout::parse_text(&text)?,
            "banamex" => banamex_layout::parse_text(&text)?,
            other => {
                eprintln!("unknown bank: {other}");
                std::process::exit(2);
            }
        }
    };

    println!("=== {bank}: {} transactions ===", txs.len());
    let show = |t: &patrimonio::models::import::ParsedTransaction| {
        let desc: String = t.description.chars().take(48).collect();
        println!(
            "  {}  {:>14}  bal={:>14}  {}",
            t.date,
            t.amount.to_string(),
            t.balance_after
                .map(|b| b.to_string())
                .unwrap_or_else(|| "-".into()),
            desc
        );
    };
    for t in txs.iter().take(6) {
        show(t);
    }
    if txs.len() > 8 {
        println!("  ...");
        for t in txs.iter().rev().take(2).rev() {
            show(t);
        }
    }

    // Sanity aggregates.
    let deposits = txs.iter().filter(|t| t.amount.is_sign_positive()).count();
    let withdrawals = txs.len() - deposits;
    let with_balance = txs.iter().filter(|t| t.balance_after.is_some()).count();
    println!(
        "  deposits={deposits} withdrawals={withdrawals} with_balance={with_balance}"
    );
    Ok(())
}
