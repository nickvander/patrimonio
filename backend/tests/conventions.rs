//! Structural convention guards for the backend source tree.
//!
//! Mirrors the frontend's `frontend/test/conventions/` suite: walk the source,
//! flag rule violations with file:line context, and keep any tolerated
//! offenders in a FROZEN allowlist whose counts must match reality exactly.
//!
//! Needs no database — it reads `src/**/*.rs` off disk — so it always runs,
//! even for contributors without a test DB configured.

use std::fs;
use std::path::{Path, PathBuf};

/// The compile-time sqlx macros are banned (skills/rust-backend SKILL.md §3):
/// they need a live `DATABASE_URL` (or a maintained `.sqlx` offline cache) at
/// build time, and this repo's Docker/offline builds have neither — one
/// `sqlx::query!` would break every DB-less build. House rule: runtime
/// `sqlx::query()` / `query_as::<_, T>()` / `query_scalar()` only.
///
/// Matched as macro *invocations* (`name!` followed by an opening bracket),
/// with comments and string literals stripped first, so prose like this
/// comment — or an error message quoting the macro name — can't false-positive.
const BANNED_SQLX_MACROS: &[&str] = &[
    "query!",
    "query_as!",
    "query_scalar!",
    "query_file!",
    "query_file_as!",
    "query_file_scalar!",
];

/// Frozen exceptions: src-relative path → (hits, reason). The count must match
/// reality EXACTLY — fixing an offender means shrinking the entry, and a new
/// offender in an already-listed file still fails. Keep this list empty.
const FROZEN_EXCEPTIONS: &[(&str, usize, &str)] = &[];

#[test]
fn src_has_no_compile_time_sqlx_macros() {
    let src_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    collect_rs_files(&src_root, &mut files);
    assert!(
        !files.is_empty(),
        "convention scan found no .rs files under {} — walker is broken",
        src_root.display()
    );
    files.sort();

    let mut hits_by_file: Vec<(String, Vec<String>)> = Vec::new();
    for file in &files {
        let rel = file
            .strip_prefix(env!("CARGO_MANIFEST_DIR"))
            .unwrap_or(file)
            .display()
            .to_string();
        let rel = rel.trim_start_matches('/').to_string();
        let source =
            fs::read_to_string(file).unwrap_or_else(|e| panic!("read {}: {e}", file.display()));
        // Blank out comments + string literals so only real code is scanned.
        let scrubbed = scrub_comments_and_strings(&source);
        let mut hits = Vec::new();
        for (idx, line) in scrubbed.lines().enumerate() {
            for name in BANNED_SQLX_MACROS {
                if has_macro_invocation(line, name) {
                    // Report the ORIGINAL line so the offender is recognizable.
                    let original = source.lines().nth(idx).unwrap_or("").trim();
                    hits.push(format!("{rel}:{}: {original}", idx + 1));
                }
            }
        }
        if !hits.is_empty() {
            hits_by_file.push((rel, hits));
        }
    }

    let mut failures = Vec::new();
    for (rel, hits) in &hits_by_file {
        match FROZEN_EXCEPTIONS.iter().find(|(p, _, _)| p == rel) {
            None => failures.push(format!(
                "{}\n  RULE: compile-time sqlx macros (query!/query_as!/query_scalar!) are \
                 banned — offline/Docker builds have no DATABASE_URL, so the macro breaks \
                 every DB-less build. Use runtime sqlx::query(...).bind(...) instead \
                 (see .agent/skills/rust-backend/SKILL.md §3). For a genuinely \
                 unavoidable exception, add a FROZEN_EXCEPTIONS entry with a reason.",
                hits.join("\n")
            )),
            Some((_, allowed, _)) if hits.len() != *allowed => failures.push(format!(
                "{rel}: expected exactly {allowed} frozen compile-time sqlx macro hit(s), \
                 found {}:\n{}\n  Fix new offenders via runtime sqlx::query(); if you \
                 removed a frozen one, shrink its FROZEN_EXCEPTIONS entry.",
                hits.len(),
                hits.join("\n")
            )),
            Some(_) => {}
        }
    }
    // A frozen entry whose file no longer hits at all is stale — prune it.
    for (path, _, _) in FROZEN_EXCEPTIONS {
        if !hits_by_file.iter().any(|(rel, _)| rel == path) {
            failures.push(format!(
                "{path}: listed in FROZEN_EXCEPTIONS but no longer contains a \
                 compile-time sqlx macro — delete the stale entry."
            ));
        }
    }

    assert!(failures.is_empty(), "\n{}\n", failures.join("\n\n"));
}

fn collect_rs_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = fs::read_dir(dir).unwrap_or_else(|e| panic!("read_dir {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            collect_rs_files(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// True when `line` (already comment/string-scrubbed) invokes macro `name`
/// (which includes its trailing `!`): the name appears on an identifier
/// boundary and the next non-space char opens a delimiter. This is what
/// distinguishes `sqlx::query!(...)` from the runtime `sqlx::query(...)` and
/// from a mention of the name inside prose (already scrubbed anyway).
fn has_macro_invocation(line: &str, name: &str) -> bool {
    let mut from = 0;
    while let Some(pos) = line[from..].find(name) {
        let start = from + pos;
        let boundary_ok = start == 0
            || !line[..start]
                .chars()
                .next_back()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_');
        let after = line[start + name.len()..].trim_start();
        if boundary_ok && matches!(after.chars().next(), Some('(' | '[' | '{')) {
            return true;
        }
        from = start + name.len();
    }
    false
}

/// Replace the contents of comments (`//…`, nested `/* … */`) and string
/// literals (normal, raw `r#"…"#`, byte) with spaces, preserving newlines so
/// line numbers still address the original file. Char literals are skipped so
/// a `'"'` can't open a phantom string.
fn scrub_comments_and_strings(source: &str) -> String {
    let bytes: Vec<char> = source.chars().collect();
    let mut out = String::with_capacity(source.len());
    let mut i = 0;
    let n = bytes.len();
    let keep = |c: char| if c == '\n' { '\n' } else { ' ' };

    while i < n {
        let c = bytes[i];
        // Line comment
        if c == '/' && i + 1 < n && bytes[i + 1] == '/' {
            while i < n && bytes[i] != '\n' {
                out.push(' ');
                i += 1;
            }
            continue;
        }
        // Block comment (nested)
        if c == '/' && i + 1 < n && bytes[i + 1] == '*' {
            let mut depth = 0;
            while i < n {
                if bytes[i] == '/' && i + 1 < n && bytes[i + 1] == '*' {
                    depth += 1;
                    out.push(' ');
                    out.push(' ');
                    i += 2;
                } else if bytes[i] == '*' && i + 1 < n && bytes[i + 1] == '/' {
                    depth -= 1;
                    out.push(' ');
                    out.push(' ');
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    out.push(keep(bytes[i]));
                    i += 1;
                }
            }
            continue;
        }
        // Raw string r"…" / r#"…"# (with optional b prefix)
        let raw_start = if c == 'r' {
            Some(i)
        } else if c == 'b' && i + 1 < n && bytes[i + 1] == 'r' {
            Some(i + 1)
        } else {
            None
        };
        if let Some(r_idx) = raw_start {
            let mut j = r_idx + 1;
            let mut hashes = 0;
            while j < n && bytes[j] == '#' {
                hashes += 1;
                j += 1;
            }
            if j < n && bytes[j] == '"' {
                // Emit placeholders up to and including the opening quote.
                while i <= j {
                    out.push(' ');
                    i += 1;
                }
                // Scan for closing `"` + hashes.
                'raw: while i < n {
                    if bytes[i] == '"' {
                        let mut k = 0;
                        while k < hashes && i + 1 + k < n && bytes[i + 1 + k] == '#' {
                            k += 1;
                        }
                        if k == hashes {
                            for _ in 0..=hashes {
                                out.push(' ');
                                i += 1;
                            }
                            break 'raw;
                        }
                    }
                    out.push(keep(bytes[i]));
                    i += 1;
                }
                continue;
            }
        }
        // Normal string (incl. b"…"), with escapes
        if c == '"' || (c == 'b' && i + 1 < n && bytes[i + 1] == '"') {
            if c == 'b' {
                out.push(' ');
                i += 1;
            }
            out.push(' ');
            i += 1; // past opening quote
            while i < n {
                if bytes[i] == '\\' {
                    out.push(' ');
                    out.push(' ');
                    i += 2;
                } else if bytes[i] == '"' {
                    out.push(' ');
                    i += 1;
                    break;
                } else {
                    out.push(keep(bytes[i]));
                    i += 1;
                }
            }
            continue;
        }
        // Char literal vs lifetime
        if c == '\'' {
            if i + 1 < n && bytes[i + 1] == '\\' {
                // '\x' escape char literal — consume through closing quote
                out.push(' ');
                i += 1;
                while i < n && bytes[i] != '\'' {
                    out.push(' ');
                    i += 1;
                }
                if i < n {
                    out.push(' ');
                    i += 1;
                }
                continue;
            }
            if i + 2 < n && bytes[i + 2] == '\'' {
                // 'x' char literal
                out.push(' ');
                out.push(' ');
                out.push(' ');
                i += 3;
                continue;
            }
            // lifetime — fall through as code
        }
        out.push(c);
        i += 1;
    }
    out
}

#[test]
fn macro_invocation_matcher_self_test() {
    // Invocation forms hit…
    assert!(has_macro_invocation("sqlx::query!(\"SELECT 1\")", "query!"));
    assert!(has_macro_invocation("query_as! ( Foo, ", "query_as!"));
    // …while the runtime API and lookalike idents do not.
    assert!(!has_macro_invocation("sqlx::query(SQL).bind(id)", "query!"));
    assert!(!has_macro_invocation("my_query!(x)", "query!"));
    // `query_as!` must not be reported as `query!` (boundary via the `_`).
    assert!(!has_macro_invocation("sqlx::query_as!(Foo)", "query!"));
    // Scrubbing removes mentions in comments and strings.
    let scrubbed =
        scrub_comments_and_strings("// never use sqlx::query!(…)\nlet s = \"query_as!(x)\";\n");
    assert!(!scrubbed.contains("query!"));
    assert!(!scrubbed.contains("query_as!"));
}
