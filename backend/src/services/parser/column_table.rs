//! Shared machinery for `pdftotext -layout` column-table statement parsers
//! (Banorte, HSBC, Scotiabank). These banks all lay their movements table out
//! as fixed spatial columns — a deposit column, a withdrawal column, and a
//! running balance — and differ only in the header words, the date format, and
//! the page furniture. The common need is:
//!
//!  * learn the column geometry from the header row, and
//!  * bucket each money token on a row into deposit / withdrawal / balance by
//!    which header column its centre is **nearest** to.
//!
//! Nearest-column assignment (rather than `<` boundary math) is what lets one
//! helper cover HSBC, whose statement prints the withdrawal column BEFORE the
//! deposit column — the opposite order of every other Mexican bank.

use super::layout_util::{amounts_with_pos, char_col};
use rust_decimal::Decimal;

/// Character columns of the three money headers on the detected header row.
#[derive(Clone, Copy, Debug)]
pub struct ColCols {
    pub deposit: usize,
    pub withdrawal: usize,
    pub saldo: usize,
}

fn first_col(upper: &str, aliases: &[&str]) -> Option<usize> {
    aliases
        .iter()
        .filter_map(|a| upper.find(a).map(|b| char_col(upper, b)))
        .min()
}

/// Detect the deposit/withdrawal/balance column geometry from a header line.
/// `dep_aliases` / `wd_aliases` are the uppercase header words each bank uses
/// (e.g. `["DEPOSITO", "ABONO"]`, `["RETIRO", "CARGO"]`). Returns None unless
/// all three are present and at distinct positions.
pub fn detect_cols(line: &str, dep_aliases: &[&str], wd_aliases: &[&str]) -> Option<ColCols> {
    let upper = line.to_uppercase();
    let deposit = first_col(&upper, dep_aliases)?;
    let withdrawal = first_col(&upper, wd_aliases)?;
    let saldo = upper.rfind("SALDO").map(|b| char_col(&upper, b))?;
    if deposit == withdrawal || deposit == saldo || withdrawal == saldo {
        return None;
    }
    Some(ColCols {
        deposit,
        withdrawal,
        saldo,
    })
}

/// Bucket every money token on a row into (deposit, withdrawal, saldo) by
/// nearest header column. Works regardless of column order.
pub fn bucket(line: &str, cols: ColCols) -> (Option<Decimal>, Option<Decimal>, Option<Decimal>) {
    let (mut dep, mut wd, mut saldo) = (None, None, None);
    for a in amounts_with_pos(line) {
        let dd = (a.center as i64 - cols.deposit as i64).abs();
        let dw = (a.center as i64 - cols.withdrawal as i64).abs();
        let ds = (a.center as i64 - cols.saldo as i64).abs();
        if dd <= dw && dd <= ds {
            dep = Some(a.value);
        } else if dw <= ds {
            wd = Some(a.value);
        } else {
            saldo = Some(a.value);
        }
    }
    (dep, wd, saldo)
}

/// Fallback bucketing when no header geometry was found: the last money token
/// on the row is the running balance, and a preceding one (if any) is the
/// movement. Sign is unknown, so it's treated as a withdrawal — the import
/// preview lets the user flip it.
pub fn bucket_no_header(line: &str) -> (Option<Decimal>, Option<Decimal>, Option<Decimal>) {
    let amts = amounts_with_pos(line);
    match amts.len() {
        0 => (None, None, None),
        1 => (None, None, Some(amts[0].value)),
        n => (None, Some(amts[n - 2].value), Some(amts[n - 1].value)),
    }
}

/// Collapse runs of whitespace in a joined description.
pub fn normalize_desc(parts: &[String]) -> String {
    parts
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
