pub mod nu_mexico;
pub mod nu_mexico_pdf;
pub mod banamex;
pub mod cetes;
pub mod cetes_pdf;
pub mod banamex_pdf;
pub mod banamex_layout;
pub mod bbva_layout;
pub mod santander_layout;
pub mod layout_util;
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

/// Extract text from a PDF with poppler's `pdftotext -layout`. Far more
/// robust than the in-process lopdf extractor — official Banamex AFP→PDF
/// statements that lopdf reports as "0 pages" extract cleanly here.
/// `-layout` preserves column geometry so the RETIROS / DEPÓSITOS / SALDO
/// columns stay aligned, which `banamex_layout` relies on. Returns an
/// empty string when pdftotext is absent or fails (callers fall back to
/// lopdf).
fn pdftotext_layout(data: &[u8]) -> String {
    let in_path = std::env::temp_dir().join(format!("pt_{}.pdf", uuid::Uuid::new_v4()));
    if fs::write(&in_path, data).is_err() {
        return String::new();
    }
    let output = Command::new("pdftotext")
        .arg("-layout")
        .arg("-enc")
        .arg("UTF-8")
        .arg(&in_path)
        .arg("-")
        .output();
    let _ = fs::remove_file(&in_path);
    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => String::new(),
    }
}

/// OCR an image-only / scanned PDF (incl. browser "Print to PDF"
/// statements whose only text layer is the "about:blank" header — the
/// real content is in page images). Tries the EXTRACTED page images first
/// (preserves the scan's native resolution; rasterizing a low-DPI image
/// loses text), and falls back to rasterizing the page (which handles
/// vector overlays / multi-image pages). Tesseract runs in Spanish,
/// `--psm 6` with preserved interword spacing so the columns stay aligned
/// for `banamex_layout`. SLOW — only a last resort. Returns "" on failure.
fn ocr_extract(data: &[u8]) -> String {
    let via_images = ocr_pages(data, true);
    if via_images.chars().filter(|c| c.is_alphabetic()).count() > 200 {
        return via_images;
    }
    let via_raster = ocr_pages(data, false);
    if via_raster.len() >= via_images.len() {
        via_raster
    } else {
        via_images
    }
}

/// Produce page images (via `pdfimages -png` when `extract`, else
/// `pdftoppm` rasterization), OCR each in page order, and return the
/// concatenated text. Cleans up its temp files.
fn ocr_pages(data: &[u8], extract: bool) -> String {
    let dir = std::env::temp_dir();
    let id = uuid::Uuid::new_v4();
    let pdf_path = dir.join(format!("ocr_{id}.pdf"));
    if fs::write(&pdf_path, data).is_err() {
        return String::new();
    }
    let prefix = format!("ocr_{id}_pg");
    let out_base = dir.join(&prefix);
    let (ok, ext) = if extract {
        let r = Command::new("pdfimages")
            .arg("-png")
            .arg(&pdf_path)
            .arg(&out_base)
            .output();
        (r.map(|o| o.status.success()).unwrap_or(false), ".png")
    } else {
        let r = Command::new("pdftoppm")
            .arg("-r")
            .arg("300")
            .arg(&pdf_path)
            .arg(&out_base)
            .output();
        (r.map(|o| o.status.success()).unwrap_or(false), ".ppm")
    };
    let _ = fs::remove_file(&pdf_path);
    if !ok {
        return String::new();
    }

    let mut pages: Vec<std::path::PathBuf> = fs::read_dir(&dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.starts_with(&prefix) && n.ends_with(ext))
                        .unwrap_or(false)
                })
                .collect()
        })
        .unwrap_or_default();
    pages.sort();

    let mut out = String::new();
    for pg in &pages {
        if let Ok(o) = Command::new("tesseract")
            .arg(pg)
            .arg("-")
            .arg("-l")
            .arg("spa")
            .arg("--psm")
            .arg("6")
            .arg("-c")
            .arg("preserve_interword_spaces=1")
            .output()
        {
            if o.status.success() {
                out.push_str(&String::from_utf8_lossy(&o.stdout));
                out.push('\n');
            }
        }
        let _ = fs::remove_file(pg);
    }
    out
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
                    t.original_description = Some(raw.clone());
                }
                t.description = polished;
                // Auto-categorize when the parser didn't already set one.
                // We classify against the RAW bank line (it still carries
                // the "COMPRA" / "PAGO" / "SPEI" signal words that
                // polish_description strips), so the preview shows a
                // category and it round-trips to confirm.
                if t.category.is_none() {
                    let basis = if raw.is_empty() { &t.description } else { &raw };
                    t.category = crate::services::categorize::categorize(basis, t.amount);
                }
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

        // Extract text with BOTH engines and keep the richer result:
        // poppler's `pdftotext` (robust — reads the official AFP→PDF
        // Banamex statements lopdf returns "0 pages" for) and the
        // in-process lopdf. Gate on readability first so a blank browser
        // printout or a scanned/image PDF gets a specific, actionable
        // message instead of a vague "couldn't identify institution".
        let pdf_text = pdftotext_layout(data);
        let lopdf_text = extract_doc_text(&doc);
        let mut best = if pdf_text.trim().len() >= lopdf_text.trim().len() {
            pdf_text
        } else {
            lopdf_text
        };

        // Run OCR when the extracted text is either sparse (image-only /
        // scanned) OR is just a browser "Print to PDF" header. Firefox
        // print-to-PDF statements render the real content as page images
        // and leave only "about:blank … N of M" in the text layer — there
        // are *enough* header letters to clear a simple length check, so we
        // trigger on the marker too. OCR (slow) only as a last resort.
        let alpha = |s: &str| s.chars().filter(|c| c.is_alphabetic()).count();
        let is_browser_print = best.to_uppercase().contains("ABOUT:BLANK");
        // Track whether the text we ultimately parse came from OCR, so the
        // preview can flag those rows for review (OCR can misread a digit).
        let mut ocr_used = false;
        if is_browser_print || alpha(&best) < 100 {
            info!("PDF '{}' looks image-only — running OCR…", file_name);
            let ocr = ocr_extract(data);
            if alpha(&ocr) > alpha(&best) {
                info!("OCR recovered {} chars for '{}'", ocr.len(), file_name);
                best = ocr;
                ocr_used = true;
            }
        }
        if let Some(reason) = unreadable_reason(&best) {
            info!("PDF '{}' is unreadable: {}", file_name, reason);
            return Err(anyhow!(reason));
        }
        let sample_text = best.to_uppercase();
        info!("PDF '{}': {} chars of usable text", file_name, best.len());

        // Each rung WINS only if its parser produces rows; otherwise we
        // fall through to the next rung and ultimately the generic parser,
        // so a misdetected (but real) statement still gets a chance.
        macro_rules! try_rows {
            ($rows:expr, $why:expr) => {{
                let rows = $rows;
                if !rows.is_empty() {
                    info!("Parsed {} transactions via {}", rows.len(), $why);
                    let mut polished = polish_all(Ok(rows))?;
                    if ocr_used {
                        for t in &mut polished {
                            t.from_ocr = true;
                        }
                    }
                    return Ok(polished);
                }
            }};
        }

        let looks_banamex = lower_name.contains("banamex")
            || sample_text.contains("BANAMEX")
            || sample_text.contains("BANCO NACIONAL DE MEXICO")
            || sample_text.contains("CITIBANAMEX")
            || sample_text.contains("BNM840515VB1");
        // Banamex (incl. MiCuenta + OCR'd scans): the column-layout parser
        // over the extracted/OCR text is primary; legacy lopdf is fallback.
        if looks_banamex {
            try_rows!(
                banamex_layout::parse_text(&best).unwrap_or_default(),
                "banamex-layout"
            );
            try_rows!(banamex_pdf::parse(data).unwrap_or_default(), "banamex-lopdf");
        }

        // BBVA México (BBVA Bancomer): the "Detalle de Movimientos
        // Realizados" column layout over pdftotext/OCR text.
        let looks_bbva = lower_name.contains("bbva")
            || lower_name.contains("bancomer")
            || sample_text.contains("BBVA")
            || sample_text.contains("BANCOMER")
            || sample_text.contains("BBA830831LJ2");
        if looks_bbva {
            try_rows!(
                bbva_layout::parse_text(&best).unwrap_or_default(),
                "bbva-layout"
            );
        }

        // Santander México ("Estado de Cuenta Integral").
        let looks_santander = lower_name.contains("santander")
            || sample_text.contains("SANTANDER")
            || sample_text.contains("BSM970519DU8")
            || sample_text.contains("ESTADO DE CUENTA INTEGRAL");
        if looks_santander {
            try_rows!(
                santander_layout::parse_text(&best).unwrap_or_default(),
                "santander-layout"
            );
        }

        // Cetes / Nu — their PDFs differ; keep the existing lopdf parsers.
        if lower_name.contains("cetes")
            || sample_text.contains("CETESDIRECTO")
            || (sample_text.contains("NACIONAL FINANCIERA") && sample_text.contains("CETES"))
        {
            try_rows!(cetes_pdf::parse(data).unwrap_or_default(), "cetes");
        }
        if lower_name.contains("nu")
            || sample_text.contains("NU MEXICO")
            || sample_text.contains("NU MÉXICO FINANCIERA")
            || sample_text.contains("CUENTA NU")
            || sample_text.contains("NUBNK")
            || sample_text.contains("NU BANK")
        {
            // Primary: the column parser over the richer pdftotext/OCR text.
            try_rows!(nu_mexico_pdf::parse_text(&best).unwrap_or_default(), "nu-layout");
            // Fallback: the in-process lopdf extraction.
            try_rows!(nu_mexico_pdf::parse(data).unwrap_or_default(), "nu-lopdf");
        }

        // Broad Mexican-bank indicators → try the Banamex layout parser.
        if sample_text.contains("ESTADO DE CUENTA")
            || sample_text.contains("CLABE")
            || sample_text.contains("MOVIMIENTOS")
            || sample_text.contains("SALDO ANTERIOR")
        {
            try_rows!(
                banamex_layout::parse_text(&best).unwrap_or_default(),
                "broad-banamex-layout"
            );
            try_rows!(banamex_pdf::parse(data).unwrap_or_default(), "broad-banamex-lopdf");
        }

        // Generic heuristic fallback: pull date/description/amount runs out
        // of the richer text. Catches unsupported banks (and known banks
        // the dedicated parser missed). The import preview lets the user
        // vet these before confirming.
        try_rows!(generic_pdf::parse_text(&best).unwrap_or_default(), "generic");

        // There WAS readable text, but nothing parsed as a transaction —
        // most likely an unsupported layout. Ask for a sample rather than
        // blaming the file.
        return Err(anyhow!(
            "Couldn't find any transactions in '{}'. If this is a real statement, its layout \
             isn't supported yet — share a sample and we can add it. (Built-in support: Nu, \
             Banamex, BBVA, Santander, CetesDirecto, plus CSV exports.)",
            file_name
        ));
    }

    Err(anyhow!("Could not identify institution for file: {}. Please ensure the file is a supported PDF or CSV from Nu, Banamex, BBVA, Santander, or CetesDirecto.", file_name))
}
