pub mod nu_mexico;
pub mod nu_mexico_pdf;
pub mod banamex;
pub mod cetes;
pub mod cetes_pdf;
pub mod banamex_pdf;
pub mod generic_pdf;

#[cfg(test)]
mod tests;

use crate::models::import::ParsedTransaction;
use anyhow::{Result, anyhow};
use lopdf::Document;
use tracing::{debug, info};
use std::io::Write;
use std::process::{Command, Stdio};
use std::fs;

/// Decrypt a password-protected PDF using qpdf.
///
/// The password is piped to qpdf via stdin (`--password-file=-`)
/// rather than passed on argv — argv is world-readable via
/// `/proc/$pid/cmdline` on Linux, which would let any other process on
/// the host read the user's PDF password while qpdf runs.
fn try_decrypt_with_qpdf(data: &[u8], password: &str) -> Result<Vec<u8>> {
    let temp_dir = std::env::temp_dir();
    let in_path = temp_dir.join(format!("in_{}.pdf", uuid::Uuid::new_v4()));
    let out_path = temp_dir.join(format!("out_{}.pdf", uuid::Uuid::new_v4()));

    {
        let mut file = fs::File::create(&in_path)?;
        file.write_all(data)?;
    }

    let mut child = Command::new("qpdf")
        .arg("--password-file=-")
        .arg("--decrypt")
        .arg(&in_path)
        .arg(&out_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("Failed to spawn qpdf: {}", e))?;

    if let Some(mut stdin) = child.stdin.take() {
        // Best effort: a write failure here usually means qpdf already
        // exited (e.g. binary missing). We propagate via .wait() below.
        let _ = stdin.write_all(password.as_bytes());
    }

    let output = child
        .wait_with_output()
        .map_err(|e| anyhow!("Failed to wait on qpdf: {}", e))?;

    let _ = fs::remove_file(&in_path);

    if !output.status.success() {
        let _ = fs::remove_file(&out_path);
        return Err(anyhow!("INCORRECT_PASSWORD"));
    }

    let decrypted_data = fs::read(&out_path)?;
    let _ = fs::remove_file(&out_path);

    Ok(decrypted_data)
}

/// Strip generic prefixes ("MISC DEBIT", "ACH PYMT", "POS ", "COMPRA ",
/// "RETIRO ", etc.) and trailing date suffixes ("20260418",
/// "18/04/2026") from a Mexican-bank parsed description when there's
/// meaningful text after stripping. Leaves the description untouched
/// when stripping would empty it out — better to show "MISC DEBIT" than
/// a blank row.
///
/// The Plaid path gets this same allowlist at display time via
/// `frontend/lib/utils/transaction_display.dart`, where it can fall back
/// to merchant/counterparty when the description is generic. The
/// Mexican parsers don't populate those columns, so we clean here
/// instead.
pub(crate) fn polish_description(raw: &str) -> String {
    // Lazy-init the regexes once per call site; cheap enough at the
    // post-parse rate (one batch per import).
    let trailing_yyyymmdd = regex::Regex::new(r"\s+\d{8}\s*$").unwrap();
    let trailing_dmy = regex::Regex::new(r"\s+\d{1,2}/\d{1,2}/\d{2,4}\s*$").unwrap();
    let trailing_mdy = regex::Regex::new(r"\s+\d{1,2}-\d{1,2}-\d{2,4}\s*$").unwrap();
    let multispace = regex::Regex::new(r"\s{2,}").unwrap();

    let mut s = raw.trim().to_string();

    // 1) Strip trailing date suffixes that some banks append.
    for re in [&trailing_yyyymmdd, &trailing_dmy, &trailing_mdy] {
        if let Some(m) = re.find(&s) {
            let trimmed = s[..m.start()].trim().to_string();
            if !trimmed.is_empty() {
                s = trimmed;
            }
        }
    }

    // 2) Strip a leading generic prefix when there's meaningful text
    //    after it. Compare case-insensitive. Bilingual list because
    //    Mexican CSV exports sometimes mix English + Spanish.
    let generic_prefixes: &[&str] = &[
        "MISCELLANEOUS DEBIT ", "MISC DEBIT ", "MISC CREDIT ",
        "ACH DEBIT ", "ACH CREDIT ", "ACH ", "POS DEBIT ", "POS PURCHASE ",
        "POS ", "DEBIT CARD ", "ELECTRONIC PAYMENT ",
        "ONLINE TRANSFER ", "ONLINE PAYMENT ",
        "BILL PAYMENT ", "BILL PAY ",
        "WIRE TRANSFER ", "WIRE ",
        "DIRECT DEBIT ", "DIRECT DEPOSIT ",
        // Spanish equivalents — `COMPRA` and `RETIRO` are sign hints in
        // banamex_pdf.rs (kept by the parser to determine debit/credit),
        // so by the time we get here the sign is already settled and
        // the prefix is just noise for display.
        "COMPRA ", "RETIRO ", "ABONO ", "CARGO ", "DEPOSITO ",
        "TRASPASO ", "PAGO ",
    ];
    let upper = s.to_uppercase();
    for prefix in generic_prefixes {
        if upper.starts_with(prefix) {
            let stripped = s[prefix.len()..].trim().to_string();
            if !stripped.is_empty() {
                s = stripped;
                break;
            }
        }
    }

    // 3) Collapse runs of whitespace from the joining + stripping work.
    multispace.replace_all(&s, " ").trim().to_string()
}

/// Apply `polish_description` to every transaction in a parser result.
/// Used by every Mexican-parser branch in `detect_and_parse` so the same
/// cleanup runs regardless of which parser fired.
///
/// Captures the pre-polish text into `original_description` when
/// polishing meaningfully changed the value. That's the raw bank line
/// the frontend's `displayLabel` ladder can fall back to when the
/// polished form turned out too terse for the row to be recognisable
/// ("DEPOSITO" → empty after stripping the generic prefix is the
/// extreme case; the helper guards against that, but plenty of rows
/// land somewhere in between).
fn polish_all(result: Result<Vec<ParsedTransaction>>) -> Result<Vec<ParsedTransaction>> {
    result.map(|txs| {
        txs.into_iter()
            .map(|mut t| {
                let raw = t.description.trim().to_string();
                let polished = polish_description(&raw);
                // Only stash the raw line when polishing actually
                // changed it — no need to duplicate identical strings
                // across two columns when the original was already
                // clean.
                if polished != raw && !raw.is_empty() {
                    t.original_description = Some(raw);
                }
                t.description = polished;
                t
            })
            .collect()
    })
}

/// Concatenate the text of every page of a loaded PDF (sorted by page
/// number). Shared by the detection gate and the generic fallback so we
/// extract once instead of per-parser.
fn extract_doc_text(doc: &Document) -> String {
    let mut out = String::new();
    let pages = doc.get_pages();
    let mut keys: Vec<_> = pages.keys().collect();
    keys.sort();
    for k in &keys {
        if let Ok(t) = doc.extract_text(&[**k]) {
            out.push_str(&t);
            out.push('\n');
        }
    }
    out
}

/// Decide whether a PDF is fundamentally unreadable (no statement text to
/// parse) and, if so, return a clear, actionable message. Runs BEFORE any
/// institution parser so a blank printout or a scan gets a specific
/// explanation instead of a vague "couldn't identify institution".
fn unreadable_reason(text: &str) -> Option<String> {
    let upper = text.to_uppercase();
    // Browser "print to PDF" of a page that never rendered: the only text
    // is the print header (the URL `about:blank`, page numbers, a
    // timestamp). Case-insensitive — the previous guard missed mixed-case
    // text and let these fall through as "0 transactions".
    if upper.contains("ABOUT:BLANK") {
        return Some(
            "This looks like a blank browser printout — the statement text didn't render. \
             Open your statement in the bank's app or website and use its \"Download PDF\" \
             button instead of printing the page."
                .to_string(),
        );
    }
    // Almost no letters across the whole document → an image-only / scanned
    // PDF with no text layer. (Stage 2 will route these through OCR.)
    let alpha = text.chars().filter(|c| c.is_alphabetic()).count();
    if alpha < 40 {
        return Some(
            "This PDF has no readable text — it looks scanned or image-based. \
             Automatic recognition for scanned statements is coming; for now, download \
             the digital PDF from your bank rather than a scan, photo, or screenshot."
                .to_string(),
        );
    }
    None
}

pub fn detect_and_parse(file_name: &str, original_data: &[u8], password: Option<&str>) -> Result<Vec<ParsedTransaction>> {
    let mut data_vec = original_data.to_vec();
    let lower_name = file_name.to_lowercase();
    
    // Decrypt if password is provided and it's a PDF
    if lower_name.ends_with(".pdf") {
        if let Some(pwd) = password {
            if !pwd.trim().is_empty() {
                info!("Decrypting PDF using provided password via qpdf...");
                data_vec = try_decrypt_with_qpdf(&data_vec, pwd)?;
            }
        }
    }
    
    let data = &data_vec;
    
    // 1. CSV Detection & Parsing
    if lower_name.ends_with(".csv") {
        // Try filename keyword first
        if lower_name.contains("nu") {
            return polish_all(nu_mexico::parse_csv(data));
        }
        if lower_name.contains("banamex") {
            return polish_all(banamex::parse_csv(data));
        }
        if lower_name.contains("cetes") {
            return polish_all(cetes::parse_csv(data));
        }

        // Fallback: Check content (headers)
        let content = String::from_utf8_lossy(data);
        let first_line = content.lines().next().unwrap_or("");
        debug!("CSV Header for auto-detect: {}", first_line);

        if first_line.contains("Descripción") && first_line.contains("Monto") {
            // Nu usually has Fecha,Descripción,Monto
            return polish_all(nu_mexico::parse_csv(data));
        }
        if first_line.contains("Concepto") && first_line.contains("Monto") {
            // Banamex usually has Fecha,Concepto,Monto
            return polish_all(banamex::parse_csv(data));
        }
    }
    
    // 2. PDF Detection & Parsing
    if lower_name.ends_with(".pdf") {
        // First check if it is encrypted and we don't have a password
        let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF for detection: {}", e))?;
        if doc.trailer.get(b"Encrypt").is_ok() {
            return Err(anyhow!("PASSWORD_REQUIRED"));
        }

        // Extract the text ONCE, then gate on readability before trying
        // any parser — a blank browser printout or a scanned/image PDF
        // gets a specific, actionable message instead of a vague
        // "couldn't identify institution" / silent "0 transactions".
        let full_text = extract_doc_text(&doc);
        if let Some(reason) = unreadable_reason(&full_text) {
            info!("PDF '{}' is unreadable: {}", file_name, reason);
            return Err(anyhow!(reason));
        }
        let sample_text = full_text.to_uppercase();
        info!("PDF '{}' has {} chars of text", file_name, sample_text.len());

        // Run the institution detection ladder. Each rung only WINS if its
        // parser actually produces rows — otherwise we fall through to the
        // next rung and ultimately to the generic heuristic parser, so a
        // misdetected (but real) statement still gets a chance.
        macro_rules! try_parser {
            ($parser:path, $why:expr) => {{
                let rows = $parser(data).unwrap_or_default();
                if !rows.is_empty() {
                    info!("Parsed {} transactions via {}", rows.len(), $why);
                    return polish_all(Ok(rows));
                }
            }};
        }

        // Filename keyword first (the user named it).
        if lower_name.contains("nu") {
            try_parser!(nu_mexico_pdf::parse, "filename=nu");
        } else if lower_name.contains("cetes") {
            try_parser!(cetes_pdf::parse, "filename=cetes");
        } else if lower_name.contains("banamex") {
            try_parser!(banamex_pdf::parse, "filename=banamex");
        }

        // Content signatures.
        if sample_text.contains("BANAMEX")
            || sample_text.contains("BANCO NACIONAL DE MEXICO")
            || sample_text.contains("CITIBANAMEX")
            || sample_text.contains("BNM840515VB1")
        {
            try_parser!(banamex_pdf::parse, "content=banamex");
        }
        if sample_text.contains("CETESDIRECTO")
            || (sample_text.contains("NACIONAL FINANCIERA") && sample_text.contains("CETES"))
        {
            try_parser!(cetes_pdf::parse, "content=cetes");
        }
        if sample_text.contains("NU MEXICO")
            || sample_text.contains("NUBNK")
            || sample_text.contains("NU BANK")
        {
            try_parser!(nu_mexico_pdf::parse, "content=nu");
        }

        // Broad Mexican-bank indicators → the Banamex parser is the most
        // capable general reader of these layouts.
        if sample_text.contains("ESTADO DE CUENTA")
            || sample_text.contains("CLABE")
            || sample_text.contains("MOVIMIENTOS")
            || sample_text.contains("SALDO ANTERIOR")
        {
            try_parser!(banamex_pdf::parse, "broad-indicators=banamex");
        }

        // PDF metadata (Title/Producer/Author/Subject) naming the bank.
        if let Ok(info_ref) = doc.trailer.get(b"Info") {
            if let Ok(dict) = info_ref.as_dict() {
                let mut meta_text = String::new();
                let keys: &[&[u8]] = &[b"Title", b"Producer", b"Author", b"Subject"];
                for key in keys {
                    if let Ok(val) = dict.get(*key) {
                        if let Ok(s) = val.as_str() {
                            meta_text.push_str(&String::from_utf8_lossy(s).to_uppercase());
                            meta_text.push(' ');
                        }
                    }
                }
                if meta_text.contains("BANAMEX") || meta_text.contains("CITIBANAMEX") {
                    try_parser!(banamex_pdf::parse, "metadata=banamex");
                }
                if meta_text.contains("NU") {
                    try_parser!(nu_mexico_pdf::parse, "metadata=nu");
                }
                if meta_text.contains("CETES") {
                    try_parser!(cetes_pdf::parse, "metadata=cetes");
                }
            }
        }

        // Generic heuristic fallback: pull date/description/amount runs out
        // of the already-extracted text. Catches unsupported banks (and
        // known banks the dedicated parser didn't recognise). The import
        // preview lets the user vet these before confirming.
        let generic = generic_pdf::parse_text(&full_text).unwrap_or_default();
        if !generic.is_empty() {
            info!("Generic parser recovered {} transactions from '{}'", generic.len(), file_name);
            return polish_all(Ok(generic));
        }

        // There WAS readable text, but nothing parsed as a transaction —
        // most likely an unsupported layout. Ask for a sample rather than
        // blaming the file.
        return Err(anyhow!(
            "Couldn't find any transactions in '{}'. If this is a real statement, its layout \
             isn't supported yet — share a sample and we can add it. (Built-in support: Nu, \
             Banamex, CetesDirecto, plus CSV exports.)",
            file_name
        ));
    }

    Err(anyhow!("Could not identify institution for file: {}. Please ensure the file is a supported PDF or CSV from Nu, Banamex, or CetesDirecto.", file_name))
}
