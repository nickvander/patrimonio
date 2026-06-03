# Statement import — architecture & future scope

> **Last updated:** 2026-06-02 (after the Banamex multi-format import + OCR sprint)
> **Purpose:** Document the statement-import pipeline as it stands, its known
> limitations, and a prioritized backlog for the next session. The import
> system was substantially rebuilt this sprint; this is the map.

---

## What ships today (as-built)

PDF/CSV statement import for Mexican banks (Banamex/MiCuenta, Nu, CetesDirecto),
with a layered extraction + parse pipeline. Entry: `POST /api/imports/upload`
(multipart, ≤100 MB), preview, then `POST /api/imports/confirm`.

**Extraction ladder** (`backend/src/services/parser/mod.rs::detect_and_parse`):
1. `pdftotext -layout` (poppler) — primary; reads the official Banamex
   AFP→PDF statements that lopdf returns "0 pages" for.
2. lopdf in-process extraction — kept; the richer of the two wins.
3. **OCR** (`ocr_extract`) when the text is sparse OR is just a browser
   "Print to PDF" header (`about:blank`): `pdfimages -png` extraction first
   (preserves low-DPI scans), `pdftoppm` rasterization fallback, then
   `tesseract -l spa --psm 6 -c preserve_interword_spaces=1` (keeps columns).
4. Readability gate: a genuinely empty result returns an actionable message.

**Parsers:**
- `banamex_layout.rs` — the workhorse. Parses pdftotext/OCR **column** layout
  (`DD MMM` date, wrapped concepto, RETIROS/DEPÓSITOS/SALDO columns). Sign from
  the running-balance delta. Key rules: **stops at the 2nd date-led "SALDO
  ANTERIOR"** (statements bundle a primary MiCuenta + a Pagaré/Inversión
  sub-account — we parse only the primary to avoid double-counting transfers +
  daily-interest noise); ignores `%` rates and amounts embedded in page-footer
  codes; cross-year date resolution from the "Período" line; emits
  `balance_after` (running SALDO).
- `bbva_layout.rs` — BBVA México ("Estado de Cuenta"). Parses the
  `Detalle de Movimientos Realizados` table: `OPER LIQ COD` lead-in,
  `DD/MMM` dates (year from the `Periodo` header), and CARGOS / ABONOS /
  OPERACIÓN / LIQUIDACIÓN columns bucketed by **column position** (debit vs
  credit is positional, not signed). Tolerates the "balance only on the
  day's last row" quirk. Routed by `BBVA`/`BANCOMER`/RFC `BBA830831LJ2`.
- `santander_layout.rs` — Santander México ("Estado de Cuenta Integral").
  `DD-MMM-AAAA` dates (year in the row), DEPOSITOS / RETIROS / SALDO
  positional columns, `SALDO FINAL DEL PERIODO ANTERIOR` opener skipped,
  abbreviation-legend furniture filtered. Routed by `SANTANDER`/RFC
  `BSM970519DU8`/`ESTADO DE CUENTA INTEGRAL`.
- `layout_util.rs` — shared column-bucketing helpers (`amounts_with_pos`
  with char-column centres, `col_of`, `month_abbr`, `strip_amounts`) used
  by the BBVA + Santander layout parsers.
- `banamex_pdf.rs` (legacy lopdf), `nu_mexico*.rs`, `cetes*.rs`, and
  `generic_pdf.rs` (heuristic fallback for unknown text-layer PDFs).

**Auto-categorization** (`services/categorize.rs`): a high-precision
rule pass maps a Spanish description (+ amount sign for transfers) to a
Plaid PFC **primary** code (`FOOD_AND_DRINK`, `TRANSFER_IN`, `BANK_FEES`,
…) so imported rows render through the SAME `prettyCategory` map as
Plaid-synced rows. Runs at parse time in `polish_all` (so the preview
shows it and it round-trips to confirm) with a confirm-time safety net.
Unknown rows stay honestly uncategorized (None). Preview rows now show
the assigned category as a faint chip.

**Preview/confirm UX** (`frontend/lib/screens/import_screen.dart`):
- Auto-batches uploads under the 100 MB cap; per-file checklist
  (waiting→parsing→ok/skipped) via the `/imports/progress/{job}` poll channel;
  OCR "not stuck" hint.
- Per-file source labels + exclude-by-file chips; currency-formatted amounts;
  virtualized list; **preview-time duplicate detection** (`/check-duplicates`,
  shared `tx_signature` with confirm; "Already imported" badge + auto-deselect).
- **Inline account creation** (AddAccountDialog, currency pre-set to the
  statements'); confirm sets the account's `current_balance` from the latest
  `balance_after` (idempotent).
- **Import cleanup** (broom icon → `ImportCleanupScreen`): undo a tracked
  import batch, or bulk-delete by account + date range (for pre-batch imports).
  Backed by `import_batch_id` + `import_file` columns on `transactions`.

**Validated against the user's full Banamex history:** ~50–74 statements,
2019–2026, text-layer + Firefox-print-to-image + scanned — essentially all
parse. (7 truly-blank prints aside, now fixed via OCR.)

---

## Known limitations (entry points for the backlog)

1. **Secondary accounts are dropped.** We parse only the primary MiCuenta. The
   Pagaré / Inversión / Ahorro Fácil sub-account in the same PDF is skipped
   entirely (its transfers mirror MiCuenta + its daily interest is noise) — but
   the user *does* hold that savings balance, and it's currently invisible.
2. **Dedup signature is fuzzy.** `manual:{date}:{amount}:{desc[:50]}` — two
   genuinely-distinct same-day/same-amount/same-desc rows collapse to one; and
   a description that parses slightly differently across versions re-imports.
   No per-occurrence index. No dedup vs Plaid-synced rows.
3. ~~**Imported rows aren't categorized.**~~ **DONE** — `services/categorize.rs`
   now assigns a Plaid PFC primary code at parse time (rule-based, Spanish
   merchant/keyword patterns). Long-tail / unknown merchants still land
   uncategorized by design (a wrong category is worse than none); growing
   the rule table is the incremental follow-up.
4. **Balance is a point-in-time stamp.** `current_balance` is set from the last
   import; there's no "balance over time derived from transactions" or a check
   that the imported running balance is continuous across months.
5. **5 banks now** (Banamex, BBVA, Santander, Nu, CetesDirecto). Adding a
   bank = a new layout parser; the architecture makes this incremental.
   **Caveat:** the BBVA + Santander parsers were built and unit-tested
   against `pdftotext -layout` fixtures *reconstructed from real
   transparency-portal statements* (the personal-account description
   vocabulary is plausible, not lifted from a confirmed personal PDF).
   Validate column geometry + sign bucketing against a real personal
   statement when one is available before fully trusting them.
6. **OCR has no confidence signal.** A misread amount/date imports silently
   (the preview is the only guard).

---

## Backlog — prioritized (impact-per-effort)

### 1. Import the secondary (savings/Pagaré) account as its own account  ★ high
**Why:** We currently *delete* real data — the user's Ahorro Fácil / Pagaré
balance and its (non-mirror) movements. They asked about balances being right;
this is the missing piece of their net worth.
**Scope:** In `banamex_layout`, instead of stopping at the 2nd SALDO ANTERIOR,
parse each account *section* separately (split on date-led SALDO ANTERIOR +
the account-name header above each "Detalle de operaciones"). Return
`Vec<(account_label, Vec<tx>)>`. Import flow: offer to route each section to a
separate account (auto-named from the header, e.g. "Banamex Ahorro Fácil"). Dedup
the cross-account transfer mirrors. **Where:** `banamex_layout.rs` (section
split), `imports.rs` (multi-account confirm), `import_screen.dart` (per-section
account picker).

### 2. Auto-categorize imported transactions  ★ high — ✅ SHIPPED
`services/categorize.rs`: rule pass (Spanish merchant/keyword + amount sign)
→ Plaid PFC primary code, reusing the `category.dart` taxonomy. Wired into
`polish_all` (parse time → preview chip + round-trip) with a confirm-time
safety net. Tests in `categorize.rs` + `parser/tests.rs`.
**Remaining follow-up:** grow the merchant rule table; a "learn from my
edits" pass that promotes user re-categorizations into rules.

### 3. Statement continuity / gap detection  ★ medium
**Why:** Confidence that the import is complete + correct. The SALDO ANTERIOR of
month N should equal the closing balance of month N-1; a mismatch = a missing
statement or a parse error.
**Scope:** After import, per account, sort statements by period and check
`opening[N] == closing[N-1]`. Surface "gap between Mar and May 2022" or "balance
discontinuity" in the import summary / a small report. Uses `import_file` +
`balance_after`. **Where:** a new `/imports/continuity` endpoint + a panel in
`ImportCleanupScreen` or the import result.

### 4. Harden the dedup signature  ★ medium
**Why:** Avoid the false-merge of legitimate same-day/same-amount rows and the
re-import-on-description-drift.
**Scope:** Add a per-(date,amount,desc) occurrence index to the signature; OR
switch to a content hash that's stable across parser versions (date + amount +
balance_after is a near-unique key for statement rows). Keep `tx_signature`
shared between preview-dedup and confirm. **Where:** `imports.rs::tx_signature`.

### 5. More banks  ★ medium, incremental — BBVA + Santander SHIPPED
**Done:** `bbva_layout.rs` + `santander_layout.rs` (+ shared `layout_util.rs`),
routed by content signature, unit-tested against reconstructed-from-real
fixtures. **Remaining:** HSBC, Banorte, Scotiabank, a Nu *PDF* parser
(Nu currently CSV-only). Same shape as the new layout parsers. **Highest
priority within this item:** validate BBVA + Santander against a real
*personal* statement (current fixtures use plausible personal-account
description vocab — see Known-limitation #5).

### 6. OCR confidence + review flagging  ★ low
**Why:** Catch OCR misreads before they pollute the ledger.
**Scope:** tesseract can emit per-word confidence (TSV output). Flag rows whose
amount/date came from low-confidence OCR; surface them pre-checked-but-marked in
the preview. **Where:** `ocr_pages` (tsv mode), a `confidence` field on the
preview tx.

---

## Adjacent (non-import) — already noted elsewhere
- **Lending:** payment-plan PDF/CSV export shipped this sprint; deferred
  follow-ups (multi-currency reporting conversion, mid-stream re-amortization,
  Schedule-B year-end doc) live in `work/LENDING_FEATURE.md` / `NEXT.md`.
- **Native Google Sheets export** (vs the CSV that opens in Sheets) — a real
  Google OAuth + Sheets API build; noted in the lending export work, larger
  standalone effort.

---

## Gotchas for the next agent
- Backend builds/tests run in Docker (`scripts/test.sh`, `scripts/check.sh`);
  `cargo` isn't on the host. OCR tools (tesseract/poppler) are in the **runtime**
  image only — unit tests can't exercise OCR end-to-end; test parser logic with
  pdftotext/OCR **fixture strings** (see `banamex_layout.rs` tests).
- To capture a user's real upload for offline diagnosis (they import from
  another device over the ngrok tunnel, so files never hit local disk): a temp
  dump in `upload_handler` writing to `/tmp/upload-debug` works — but it persists
  the user's financial PDFs to disk, so REMOVE it before committing and wipe the
  dir after. (Used repeatedly this sprint.)
- `check.sh` does NOT run `flutter test`; run it separately.
