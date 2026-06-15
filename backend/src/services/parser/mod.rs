pub mod healthequity;
pub mod fidelity_stockplan;
pub mod nu_mexico;
pub mod nu_mexico_pdf;
pub mod banamex;
pub mod cetes;
pub mod cetes_pdf;
pub mod banamex_pdf;
pub mod banamex_layout;
pub mod bbva_layout;
pub mod santander_layout;
pub mod banorte_layout;
pub mod scotiabank_layout;
pub mod hsbc_layout;
pub mod revolut;
pub mod column_table;
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

/// Words that appear in essentially every Mexican bank statement. Used to tell
/// a real text extraction from a garbled (broken-font) one.
const STATEMENT_ANCHORS: &[&str] = &[
    "SALDO",
    "CUENTA",
    "MOVIMIENT",
    "PERIODO",
    "PERÍODO",
    "FECHA",
    "RFC",
    "PESOS",
    "ESTADO DE CUENTA",
];

fn has_statement_anchor(text: &str) -> bool {
    let upper = text.to_uppercase();
    STATEMENT_ANCHORS.iter().any(|w| upper.contains(w))
}

/// A "garbled" extraction has plenty of letters but none of the vocabulary a
/// statement always contains — the signature of a broken embedded-font CMap
/// (e.g. some HSBC PDFs) where `pdftotext` shifts every glyph into gibberish.
/// Such files need OCR of the (visually-correct) rendered page. We require a
/// fair amount of alpha first so genuinely sparse/short text falls to the
/// existing length-based OCR trigger instead.
fn looks_garbled(text: &str) -> bool {
    let alpha = text.chars().filter(|c| c.is_alphabetic()).count();
    alpha >= 200 && !has_statement_anchor(text)
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
        // scanned) OR is just a browser "Print to PDF" header OR is GARBLED.
        // Firefox print-to-PDF statements render the real content as page
        // images and leave only "about:blank … N of M" in the text layer —
        // enough header letters to clear a length check, so we trigger on the
        // marker too. Garbled = a broken embedded-font CMap (e.g. some HSBC
        // PDFs) where `pdftotext` emits lots of letters but they're shifted
        // into gibberish — plenty of alpha, yet none of the words every
        // statement contains. OCR rasterizes the *rendered* page, which is
        // visually correct, so it recovers the real text. OCR (slow) only as a
        // last resort.
        let alpha = |s: &str| s.chars().filter(|c| c.is_alphabetic()).count();
        let is_browser_print = best.to_uppercase().contains("ABOUT:BLANK");
        let garbled = looks_garbled(&best);
        // Track whether the text we ultimately parse came from OCR, so the
        // preview can flag those rows for review (OCR can misread a digit).
        let mut ocr_used = false;
        if is_browser_print || alpha(&best) < 100 || garbled {
            info!(
                "PDF '{}' needs OCR (browser_print={}, sparse={}, garbled={}) — running…",
                file_name,
                is_browser_print,
                alpha(&best) < 100,
                garbled
            );
            let ocr = ocr_extract(data);
            // Normally adopt OCR when it recovered more letters. But a garbled
            // extraction already has *lots* of (junk) alpha, so for that case
            // prefer OCR when it recovered real statement vocabulary the
            // garbled text lacks.
            let adopt = if garbled {
                has_statement_anchor(&ocr) && !has_statement_anchor(&best)
            } else {
                alpha(&ocr) > alpha(&best)
            };
            if adopt {
                info!("OCR recovered {} chars for '{}'", ocr.len(), file_name);
                best = ocr;
                ocr_used = true;
            }
        }
        if let Some(reason) = unreadable_reason(&best) {
            info!("PDF '{}' is unreadable: {}", file_name, reason);
            return Err(anyhow!(reason));
        }
        // Opt-in debug dump: when IMPORT_DEBUG_DUMP_DIR is set, write the
        // extracted layout text to a file there. Off by default (the env var
        // is unset in production) — used to add support for a new bank layout
        // by inspecting exactly what the parser sees, without persisting any
        // statement in normal operation.
        if let Ok(dir) = std::env::var("IMPORT_DEBUG_DUMP_DIR") {
            if !dir.is_empty() {
                let safe: String = file_name
                    .chars()
                    .map(|c| if c.is_alphanumeric() || c == '.' || c == '-' { c } else { '_' })
                    .collect();
                let _ = std::fs::create_dir_all(&dir);
                let path = std::path::Path::new(&dir).join(format!("{safe}.txt"));
                if let Err(e) = std::fs::write(&path, best.as_bytes()) {
                    tracing::warn!("IMPORT_DEBUG_DUMP_DIR write failed for {}: {}", file_name, e);
                } else {
                    info!("debug-dumped extracted text for '{}' to {:?}", file_name, path);
                }
            }
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

        // HealthEquity HSA (US) — unique English markers, no overlap with the
        // Mexican-bank checks below, so it's safe to try first.
        if healthequity::looks_like(&sample_text) {
            try_rows!(
                healthequity::parse_text(&best).unwrap_or_default(),
                "healthequity-layout"
            );
        }

        // Fidelity Stock Plan Services ("NetBenefits") — US equity-comp report.
        if fidelity_stockplan::looks_like(&sample_text) {
            try_rows!(
                fidelity_stockplan::parse_text(&best).unwrap_or_default(),
                "fidelity-stockplan-layout"
            );
        }

        // Revolut Bank (Mexico) — unique English issuer marker. Checked
        // before the Mexican-bank rungs because Revolut transfer rows quote
        // counterparties like "NU MEXICO" / "STP" that could otherwise
        // misroute the file to the Nu or broad-Banamex parser.
        if revolut::looks_like(&sample_text) {
            try_rows!(revolut::parse_text(&best).unwrap_or_default(), "revolut-layout");
            try_rows!(revolut::parse(data).unwrap_or_default(), "revolut-lopdf");
        }

        // Nu México — checked FIRST, by issuer-specific markers. Nu's debit
        // statements routinely mention other banks (BANAMEX, BBVA…) inside
        // SPEI transfer descriptions, which would otherwise trip the broad
        // `contains("BANAMEX")` check below and misroute the whole file to the
        // Banamex parser. These markers only appear in Nu's own chrome.
        let looks_nu = lower_name.contains("nu méxico")
            || lower_name.contains("nu mexico")
            || sample_text.contains("NU MÉXICO FINANCIERA")
            || sample_text.contains("CUENTA NU")
            || sample_text.contains("DETALLE DE MOVIMIENTOS EN TU CUENTA")
            || sample_text.contains("DETALLE DE MOVIMIENTOS DE TUS CAJITAS");
        if looks_nu {
            try_rows!(nu_mexico_pdf::parse_text(&best).unwrap_or_default(), "nu-layout");
            try_rows!(nu_mexico_pdf::parse(data).unwrap_or_default(), "nu-lopdf");
        }

        // cetesdirecto (Nacional Financiera / NAFIN) — also checked before the
        // broad Mexican-bank fallback, since its "Movimientos del período"
        // table would otherwise be fed to the Banamex layout parser. Its
        // 2-date / Cargo-Abono-Saldo columns are unlike any bank ledger.
        let looks_cetes = lower_name.contains("cetes")
            || sample_text.contains("CETESDIRECTO")
            || sample_text.contains("MOVIMIENTOS DEL PERÍODO")
            || sample_text.contains("MOVIMIENTOS DEL PERIODO")
            || (sample_text.contains("NACIONAL FINANCIERA") && sample_text.contains("CETES"));
        if looks_cetes {
            try_rows!(cetes_pdf::parse_text(&best).unwrap_or_default(), "cetes-layout");
            try_rows!(cetes_pdf::parse(data).unwrap_or_default(), "cetes-lopdf");
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

        // Banorte (Banco Mercantil del Norte).
        let looks_banorte = lower_name.contains("banorte")
            || sample_text.contains("BANORTE")
            || sample_text.contains("BANCO MERCANTIL DEL NORTE")
            || sample_text.contains("BMN930209927");
        if looks_banorte {
            try_rows!(
                banorte_layout::parse_text(&best).unwrap_or_default(),
                "banorte-layout"
            );
        }

        // Scotiabank México (Scotiabank Inverlat). The bank RFC isn't printed
        // on the statement, so route on the legal name / UNE contact.
        let looks_scotia = lower_name.contains("scotia")
            || sample_text.contains("SCOTIABANK")
            || sample_text.contains("INVERLAT")
            || sample_text.contains("UNE@SCOTIABANK")
            || sample_text.contains("DETALLE DE TUS MOVIMIENTOS");
        if looks_scotia {
            try_rows!(
                scotiabank_layout::parse_text(&best).unwrap_or_default(),
                "scotiabank-layout"
            );
        }

        // HSBC México.
        let looks_hsbc = lower_name.contains("hsbc")
            || sample_text.contains("HSBC")
            || sample_text.contains("HMI950125KG8");
        if looks_hsbc {
            try_rows!(
                hsbc_layout::parse_text(&best).unwrap_or_default(),
                "hsbc-layout"
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
             Banamex, BBVA, Santander, CetesDirecto, HealthEquity, Fidelity Stock Plan, plus \
             CSV exports.)",
            file_name
        ));
    }

    Err(anyhow!("Could not identify institution for file: {}. Please ensure the file is a supported PDF or CSV from Nu, Banamex, BBVA, Santander, or CetesDirecto.", file_name))
}

/// Account-level metadata lifted from a statement's header/summary so the
/// import flow can pre-fill a new account (name + balance) and keep the
/// account's identifying details (CLABE, holder, RFC) in one place.
///
/// `suggested_balance` is the figure that belongs in net worth: the cetes
/// portfolio "Total final" (not its ~0 cash), or Nu's "En su Cuenta". For
/// Banamex it's left None — those statements carry a per-row running balance,
/// so the import already sets the account balance from the closing row.
/// A security the statement reports the account holding — e.g. an HSA's
/// invested fund, plus a cash sleeve. The import can turn these into
/// live-priced holdings so the account's value tracks the market between
/// statements (an HSA is mostly fund, not the ~$500 idle cash).
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ImportHolding {
    pub symbol: String,
    pub name: Option<String>,
    pub quantity: f64,
    /// Statement-reported value — used to value a cash sleeve and as a fallback
    /// when no live price is available for an equity.
    pub value: Option<f64>,
    /// A cash position: priced at 1.00 and never sent to Yahoo.
    #[serde(default)]
    pub cash: bool,
    /// Allocation bucket (`INITCAP`-ed for the Portfolio view), e.g. "mutual
    /// fund" so an HSA's target-date fund groups with the other funds rather
    /// than under Equity. None → "equity" for a non-cash holding.
    #[serde(default)]
    pub holding_type: Option<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct AccountInfo {
    pub institution: Option<String>,
    pub holder_name: Option<String>,
    pub clabe: Option<String>,
    pub rfc: Option<String>,
    pub suggested_name: Option<String>,
    pub suggested_balance: Option<f64>,
    pub currency: Option<String>,
    /// Suggested account-type VALUE for the create dialog (e.g. "Bonds" for a
    /// cetesdirecto portfolio — fixed-income securities, not cash). None lets
    /// the dialog keep its default.
    #[serde(default)]
    pub account_type: Option<String>,
    /// ISO `YYYY-MM-DD` period end, used to pick the newest statement's info.
    pub period_end: Option<String>,
    /// Securities the import should attach as live-priced holdings (currently
    /// only HealthEquity HSAs: the invested fund + a cash sleeve).
    #[serde(default)]
    pub holdings: Vec<ImportHolding>,
}

fn re_cap(pattern: &str, text: &str) -> Option<String> {
    regex::Regex::new(pattern)
        .ok()?
        .captures(text)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
}

fn clean_clabe(raw: &str) -> Option<String> {
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    (digits.len() == 18).then_some(digits)
}

/// Extract account-identifying metadata from a statement PDF. Best-effort and
/// header-only (no OCR) — returns None for CSVs, encrypted-without-password,
/// or unrecognised layouts.
pub fn parse_account_info(
    file_name: &str,
    original_data: &[u8],
    password: Option<&str>,
) -> Option<AccountInfo> {
    if !file_name.to_lowercase().ends_with(".pdf") {
        return None;
    }
    let mut data = original_data.to_vec();
    if let Some(pwd) = password {
        if let Ok(dec) = try_decrypt_with_qpdf(&data, pwd) {
            data = dec;
        }
    }
    let text = pdftotext_layout(&data);
    if text.trim().is_empty() {
        return None;
    }
    let upper = text.to_uppercase();

    if healthequity::looks_like(&upper) {
        return Some(healthequity_account_info(&text));
    }
    if fidelity_stockplan::looks_like(&upper) {
        return Some(fidelity_stockplan_account_info(&text));
    }
    if revolut::looks_like(&upper) {
        return Some(revolut_account_info(&text));
    }
    if upper.contains("NU MÉXICO FINANCIERA")
        || upper.contains("CUENTA NU")
        || upper.contains("DETALLE DE MOVIMIENTOS EN TU CUENTA")
    {
        return Some(nu_account_info(&text));
    }
    if upper.contains("CETESDIRECTO")
        || upper.contains("MOVIMIENTOS DEL PERÍODO")
        || (upper.contains("NACIONAL FINANCIERA") && upper.contains("CETES"))
    {
        return Some(cetes_account_info(&text));
    }
    if upper.contains("BANAMEX")
        || upper.contains("CITIBANAMEX")
        || upper.contains("BANCO NACIONAL DE MEXICO")
    {
        return Some(banamex_account_info(&text));
    }
    None
}

fn nu_account_info(text: &str) -> AccountInfo {
    let summary = nu_mexico_pdf::parse_account_summary(text);
    // The Nu account balance is the TOTAL the statement reports ("Saldo al
    // generar este estado de cuenta" = available + cajitas), NOT just the
    // available "En su Cuenta" — which is often $0 because the money lives in
    // cajitas (Ahorro). Preferring available made a real ~$50k account show 0.
    // Fall back to available + cajitas, then available alone.
    let bal = summary
        .saldo_total
        .or_else(|| match (summary.en_su_cuenta, summary.total_cajitas) {
            (Some(c), Some(j)) => Some(c + j),
            (other, _) => other,
        })
        .and_then(|d| d.to_string().parse::<f64>().ok());
    // Holder is the line just above "Cuenta Nu:".
    let holder = {
        let lines: Vec<&str> = text.lines().collect();
        let mut found = None;
        for (i, l) in lines.iter().enumerate() {
            if l.to_uppercase().contains("CUENTA NU") && i > 0 {
                for j in (0..i).rev() {
                    let t = lines[j].trim();
                    if !t.is_empty() {
                        found = Some(t.to_string());
                        break;
                    }
                }
                break;
            }
        }
        found
    };
    AccountInfo {
        institution: Some("Nu México".into()),
        holder_name: holder,
        clabe: re_cap(r"(?i)CLABE:\s*([\d ]{18,25})", text).and_then(|s| clean_clabe(&s)),
        rfc: re_cap(r"(?i)RFC:\s*([A-Z0-9]{10,13})", text),
        suggested_name: Some("Nu — Cuenta".into()),
        suggested_balance: bal,
        currency: Some("MXN".into()),
        account_type: Some("Checking".into()),
        period_end: nu_period_end(text),
        holdings: Vec::new(),
    }
}

fn nu_period_end(text: &str) -> Option<String> {
    // "Periodo: del 01 al 30 sep 2025"
    let c = regex::Regex::new(r"(?i)periodo:?\s*del\s+\d{1,2}\s+al\s+(\d{1,2})\s+(\w+)\s+(\d{4})")
        .ok()?
        .captures(text)?;
    let day: u32 = c[1].parse().ok()?;
    let month = match c[2].to_lowercase().chars().take(3).collect::<String>().as_str() {
        "ene" => 1, "feb" => 2, "mar" => 3, "abr" => 4, "may" => 5, "jun" => 6,
        "jul" => 7, "ago" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dic" => 12,
        _ => return None,
    };
    let year: i32 = c[3].parse().ok()?;
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

fn revolut_account_info(text: &str) -> AccountInfo {
    // Currency from the "<CCY> Statement" header (savings statements have no
    // such header → default MXN, since Revolut MX is peso-denominated).
    let currency = re_cap(r"\b([A-Z]{3}) Statement\b", text).unwrap_or_else(|| "MXN".into());
    // The newest closing balance: the personal statement bundles months, so
    // the LAST "Closing balance"/"Closing Balance" is the most recent.
    let bal = regex::Regex::new(r"(?i)Closing\s+balance\s+\$([\d,]+\.\d{2})")
        .ok()
        .and_then(|re| {
            re.captures_iter(text)
                .last()
                .and_then(|c| c[1].replace(',', "").parse::<f64>().ok())
        });
    // Holder is the first ALL-CAPS name line in the address block.
    let holder = re_cap(r"(?m)^\s*([A-Z][A-Z ]{4,}[A-Z])\s*$", text);
    AccountInfo {
        institution: Some("Revolut".into()),
        holder_name: holder,
        clabe: re_cap(r"(?i)CLABE for SPEI\s*([\d ]{18,25})", text).and_then(|s| clean_clabe(&s)),
        rfc: None,
        suggested_name: Some(if text.contains("Account transactions from") {
            "Revolut — Cuenta".into()
        } else {
            "Revolut — Instant Access Savings".into()
        }),
        suggested_balance: bal,
        currency: Some(currency),
        account_type: Some("Checking".into()),
        period_end: revolut_period_end(text),
        holdings: Vec::new(),
    }
}

fn revolut_period_end(text: &str) -> Option<String> {
    // Personal: "From April 1, 2026 to April 30, 2026"; savings:
    // "Period: Jun 1, 2026 – Jun 15, 2026". Take the LAST end-date so a
    // multi-month personal PDF reports its newest period.
    let re = regex::Regex::new(r"(?i)(?:to|–|-)\s+([A-Z][a-z]{2})\s+(\d{1,2}),\s+(20\d{2})").ok()?;
    let c = re.captures_iter(text).last()?;
    let month = revolut::month_num(&c[1])?;
    let day: u32 = c[2].parse().ok()?;
    let year: i32 = c[3].parse().ok()?;
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

fn healthequity_account_info(text: &str) -> AccountInfo {
    // The account's worth is cash + invested value, not the idle cash balance.
    let bal = healthequity::parse_total_account_value(text)
        .and_then(|d| d.to_string().parse::<f64>().ok());
    // Holder sits to the LEFT of "Account Number:" on the same layout row.
    let holder = re_cap(r"(?im)^\s*([A-Za-z][^\n]*?\S)\s{2,}Account Number:\s*\d", text);
    let acct = re_cap(r"(?i)Account Number:\s*(\d+)", text);
    let masked = acct
        .as_deref()
        .filter(|a| a.len() >= 4)
        .map(|a| format!("HealthEquity HSA \u{2022}\u{2022}{}", &a[a.len() - 4..]))
        .unwrap_or_else(|| "HealthEquity HSA".to_string());
    // The invested fund (live-priced) + a cash sleeve, so the account's worth
    // tracks the market while staying exact on the cash side.
    let mut holdings: Vec<ImportHolding> = Vec::new();
    if let Some((sym, shares, value)) = healthequity::parse_investment_holding(text) {
        holdings.push(ImportHolding {
            symbol: sym,
            name: Some("Invested funds".into()),
            quantity: shares.to_string().parse().unwrap_or(0.0),
            value: value.to_string().parse().ok(),
            cash: false,
            // HealthEquity's investment menu is mutual funds (target-date /
            // index), so group it with the other funds, not under Equity.
            holding_type: Some("mutual fund".into()),
        });
    }
    if let Some(cash) = healthequity::parse_cash_ending_balance(text) {
        let c: f64 = cash.to_string().parse().unwrap_or(0.0);
        if c > 0.0 {
            holdings.push(ImportHolding {
                symbol: "CASH".into(),
                name: Some("HSA cash".into()),
                quantity: c,
                value: Some(c),
                cash: true,
                holding_type: None,
            });
        }
    }
    AccountInfo {
        institution: Some("HealthEquity".into()),
        holder_name: holder,
        clabe: None,
        rfc: None,
        suggested_name: Some(masked),
        suggested_balance: bal,
        currency: Some("USD".into()),
        // An HSA is a tax-advantaged investment account (categorised as
        // investment); see account_category.dart.
        account_type: Some("HSA".into()),
        // "Period: 01/01/26 through 06/30/26" → 2026-06-30.
        period_end: regex::Regex::new(
            r"(?i)Period:\s*\d{2}/\d{2}/\d{2}\s+through\s+(\d{2})/(\d{2})/(\d{2})",
        )
        .ok()
        .and_then(|re| re.captures(text))
        .map(|c| format!("20{}-{}-{}", &c[3], &c[1], &c[2])),
        holdings,
    }
}

fn fidelity_stockplan_account_info(text: &str) -> AccountInfo {
    let bal = fidelity_stockplan::parse_account_value(text)
        .and_then(|d| d.to_string().parse::<f64>().ok());
    // Holder appears as "NAME - STOCK PLAN ACCOUNT" on the per-account pages.
    let holder = re_cap(r"(?im)^\s*([A-Z][A-Z .'-]{3,}?)\s+-\s+STOCK PLAN ACCOUNT", text);
    let participant = re_cap(r"(?i)Participant Number:\s*([A-Z0-9]+)", text);
    let masked = participant
        .as_deref()
        .filter(|p| p.len() >= 4)
        .map(|p| format!("Fidelity Stock Plan \u{2022}\u{2022}{}", &p[p.len() - 4..]))
        .unwrap_or_else(|| "Fidelity Stock Plan".to_string());
    AccountInfo {
        institution: Some("Fidelity NetBenefits".into()),
        holder_name: holder,
        clabe: None,
        rfc: None,
        suggested_name: Some(masked),
        suggested_balance: bal,
        currency: Some("USD".into()),
        account_type: Some("Stock plan".into()),
        period_end: fidelity_stockplan::parse_period_end(text).map(|d| d.to_string()),
        holdings: fidelity_stockplan::parse_holdings(text),
    }
}

fn cetes_account_info(text: &str) -> AccountInfo {
    let bal = cetes_pdf::parse_portfolio_total(text)
        .and_then(|d| d.to_string().parse::<f64>().ok());
    AccountInfo {
        institution: Some("CetesDirecto".into()),
        holder_name: re_cap(r"(?i)Nombre:\s*(.+)", text),
        clabe: re_cap(r"(?i)Contrato/Cuenta CLABE:\s*(\d{18})", text)
            .or_else(|| re_cap(r"(?i)CLABE:\s*(\d{18})", text)),
        rfc: re_cap(r"(?i)RFC:\s*([A-Z0-9]{10,13})", text),
        suggested_name: Some("CetesDirecto".into()),
        suggested_balance: bal,
        currency: Some("MXN".into()),
        // CETES are government T-bills (fixed income), not a cash account.
        account_type: Some("Bonds".into()),
        // "Período del: 01/04/2024 al 30/04/2024" → 2024-04-30.
        period_end: regex::Regex::new(r"(?i)al\s+(\d{2})/(\d{2})/(\d{4})")
            .ok()
            .and_then(|re| re.captures(text))
            .map(|c| format!("{}-{}-{}", &c[3], &c[2], &c[1])),
        holdings: Vec::new(),
    }
}

fn banamex_account_info(text: &str) -> AccountInfo {
    AccountInfo {
        institution: Some("Banamex".into()),
        holder_name: None,
        clabe: re_cap(r"(?i)CLABE[:\s]*([\d ]{18,25})", text).and_then(|s| clean_clabe(&s)),
        rfc: re_cap(r"(?i)RFC:\s*([A-Z0-9]{10,13})", text),
        suggested_name: Some("Banamex".into()),
        // Banamex statements carry a per-row balance; confirm sets it.
        suggested_balance: None,
        currency: Some("MXN".into()),
        account_type: Some("Checking".into()),
        period_end: None,
        holdings: Vec::new(),
    }
}
