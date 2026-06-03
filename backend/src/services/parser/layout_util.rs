//! Shared helpers for the `pdftotext -layout` column parsers
//! (`bbva_layout`, `santander_layout`, …). These banks lay their movement
//! tables out as fixed spatial columns; the common need is to read money
//! tokens together with WHERE on the line they sit, so each can be bucketed
//! into the right column (CARGOS vs ABONOS vs SALDO).

use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;

/// 3-letter uppercase Spanish month → 1-12. Shared by every MX layout
/// parser (Banamex keeps its own copy for now).
pub fn month_abbr(s: &str) -> Option<u32> {
    match s {
        "ENE" => Some(1),
        "FEB" => Some(2),
        "MAR" => Some(3),
        "ABR" => Some(4),
        "MAY" => Some(5),
        "JUN" => Some(6),
        "JUL" => Some(7),
        "AGO" => Some(8),
        "SEP" => Some(9),
        "OCT" => Some(10),
        "NOV" => Some(11),
        "DIC" => Some(12),
        _ => None,
    }
}

/// A money token plus the character column of its centre on the line.
#[derive(Debug, Clone, Copy)]
pub struct Amt {
    pub center: usize,
    pub value: Decimal,
}

/// The amount regex used across the layout parsers: `1,234.56` style,
/// always 2 decimals, optional comma thousands groups.
fn amount_re() -> Regex {
    Regex::new(r"\d{1,3}(?:,\d{3})*\.\d{2}").unwrap()
}

/// Character column (not byte offset) of a byte index within `line`.
/// Layout lines can contain accented column headers (DESCRIPCIÓN,
/// OPERACIÓN), so byte offsets drift from visual columns — we always
/// reason in chars.
pub fn char_col(line: &str, byte: usize) -> usize {
    line[..byte].chars().count()
}

/// Character column of the first occurrence of `needle` in `line`, if any.
pub fn col_of(line: &str, needle: &str) -> Option<usize> {
    line.find(needle).map(|b| char_col(line, b))
}

/// Extract every standalone money token on the line with its centre
/// column. Rejects rates (`0.50%`) and numbers embedded in a longer code
/// (`...OD.0624.01`) the same way `banamex_layout` does — those corrupt the
/// amount/balance columns otherwise.
pub fn amounts_with_pos(line: &str) -> Vec<Amt> {
    let re = amount_re();
    re.find_iter(line)
        .filter(|m| {
            if line[m.end()..].chars().next() == Some('%') {
                return false;
            }
            let before = line[..m.start()].chars().last();
            !matches!(before, Some(c) if c.is_ascii_alphanumeric() || c == '.')
        })
        .filter_map(|m| {
            let value = Decimal::from_str(&m.as_str().replace(',', "")).ok()?;
            let start = char_col(line, m.start());
            let end = char_col(line, m.end());
            Some(Amt {
                center: (start + end) / 2,
                value,
            })
        })
        .collect()
}

/// Strip every money token from a line, leaving the description text.
pub fn strip_amounts(line: &str) -> String {
    amount_re().replace_all(line, "").trim().to_string()
}
