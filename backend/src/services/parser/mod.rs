pub mod nu_mexico;
pub mod nu_mexico_pdf;
pub mod banamex;
pub mod cetes;
pub mod cetes_pdf;
pub mod banamex_pdf;

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
            return nu_mexico::parse_csv(data);
        }
        if lower_name.contains("banamex") {
            return banamex::parse_csv(data);
        }
        if lower_name.contains("cetes") {
            return cetes::parse_csv(data);
        }

        // Fallback: Check content (headers)
        let content = String::from_utf8_lossy(data);
        let first_line = content.lines().next().unwrap_or("");
        debug!("CSV Header for auto-detect: {}", first_line);

        if first_line.contains("Descripción") && first_line.contains("Monto") {
            // Nu usually has Fecha,Descripción,Monto
            return nu_mexico::parse_csv(data);
        }
        if first_line.contains("Concepto") && first_line.contains("Monto") {
            // Banamex usually has Fecha,Concepto,Monto
            return banamex::parse_csv(data);
        }
    }
    
    // 2. PDF Detection & Parsing
    if lower_name.ends_with(".pdf") {
        // First check if it is encrypted and we don't have a password
        let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF for detection: {}", e))?;
        if doc.trailer.get(b"Encrypt").is_ok() {
            return Err(anyhow!("PASSWORD_REQUIRED"));
        }

        // Try filename keyword first
        if lower_name.contains("nu") {
            return nu_mexico_pdf::parse(data);
        }
        if lower_name.contains("cetes") {
            return cetes_pdf::parse(data);
        }
        if lower_name.contains("banamex") {
            return banamex_pdf::parse(data);
        }

        // Fallback: Scan PDF content
        info!("Ambiguous PDF filename '{}'. Scanning content...", file_name);
        
        // Extract text from ALL pages for robust detection
        let mut sample_text = String::new();
        let pages = doc.get_pages();
        let mut page_keys: Vec<_> = pages.keys().collect();
        page_keys.sort();

        for page_id in &page_keys {
            if let Ok(text) = doc.extract_text(&[**page_id]) {
                sample_text.push_str(&text.to_uppercase());
                sample_text.push(' ');
            }
        }

        info!("Scanned {} pages, got {} chars of text", page_keys.len(), sample_text.len());
        debug!("PDF Sample text (first 1000 chars): {}", sample_text.chars().take(1000).collect::<String>());

        // 1. Banamex (most common)
        if sample_text.contains("BANAMEX") 
            || sample_text.contains("BANCO NACIONAL DE MEXICO") 
            || sample_text.contains("CITIBANAMEX")
            || sample_text.contains("BNM840515VB1")
        {
            return banamex_pdf::parse(data);
        }

        // 2. Cetes
        if sample_text.contains("CETESDIRECTO") || (sample_text.contains("NACIONAL FINANCIERA") && sample_text.contains("CETES")) {
            return cetes_pdf::parse(data);
        }

        // 3. Nu Mexico
        if sample_text.contains("NU MEXICO") || sample_text.contains("NUBNK") || sample_text.contains("NU BANK") {
            return nu_mexico_pdf::parse(data);
        }

        // 4. Broad Mexican bank indicators → default to Banamex
        if sample_text.contains("ESTADO DE CUENTA") 
            || sample_text.contains("CLABE")
            || sample_text.contains("MOVIMIENTOS")
            || sample_text.contains("SALDO ANTERIOR")
        {
            info!("Identified as Mexican bank statement via broad indicators, defaulting to Banamex parser");
            return banamex_pdf::parse(data);
        }

        // 5. Metadata Fallback
        if let Ok(info_ref) = doc.trailer.get(b"Info") {
            if let Ok(dict) = info_ref.as_dict() {
                let mut meta_text = String::new();
                let keys: &[&[u8]] = &[b"Title", b"Producer", b"Author", b"Subject"];
                for key in keys {
                    if let Ok(val) = dict.get(*key) {
                        if let Ok(s) = val.as_str() {
                            let t = String::from_utf8_lossy(s).to_uppercase();
                            debug!("PDF Metadata {}: {}", String::from_utf8_lossy(*key), t);
                            meta_text.push_str(&t);
                            meta_text.push(' ');
                        }
                    }
                }
                if meta_text.contains("BANAMEX") || meta_text.contains("CITIBANAMEX") {
                    info!("Identified as Banamex via PDF Metadata");
                    return banamex_pdf::parse(data);
                }
                if meta_text.contains("NU") {
                    info!("Identified as Nu Mexico via PDF Metadata");
                    return nu_mexico_pdf::parse(data);
                }
                if meta_text.contains("CETES") {
                    info!("Identified as Cetes via PDF Metadata");
                    return cetes_pdf::parse(data);
                }
            }
        }

        // 6. If we got this far with a PDF, just try Banamex as last resort
        // since the user's PDFs are predominantly from Banamex
        if sample_text.len() > 100 {
            info!("Unidentified PDF with {} chars of text — trying Banamex parser as fallback", sample_text.len());
            return banamex_pdf::parse(data);
        }
    }
    
    Err(anyhow!("Could not identify institution for file: {}. Please ensure the file is a supported PDF or CSV from Nu, Banamex, or CetesDirecto.", file_name))
}
