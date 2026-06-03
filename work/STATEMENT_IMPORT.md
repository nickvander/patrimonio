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

1. ~~**Secondary accounts are dropped.**~~ **DONE** — `banamex_layout` now
   splits a bundled statement at each "SALDO ANTERIOR" opener and parses every
   account section (resetting the running balance per section), tagging
   secondary rows with `account_label`. The import UI shows a destination
   picker per section so the Pagaré/Ahorro balance lands in its own account.
   **Caveat:** built/tested against a fixture; the secondary-section row
   fidelity (the delta parser on sparse savings rows) should be eyeballed in
   the preview against a real multi-account statement.
2. **Dedup signature is fuzzy.** ~~two genuinely-distinct same-day/same-amount/
   same-desc rows collapse to one~~ **FIXED** — `batch_signatures` adds a `#N`
   occurrence suffix to the 2nd+ exact-duplicate in a batch (first keeps the
   bare legacy signature, so already-imported history still dedups). Still
   open: a description that parses slightly differently across parser versions
   re-imports; no dedup vs Plaid-synced rows.
3. ~~**Imported rows aren't categorized.**~~ **DONE** — `services/categorize.rs`
   now assigns a Plaid PFC primary code at parse time (rule-based, Spanish
   merchant/keyword patterns). Long-tail / unknown merchants still land
   uncategorized by design (a wrong category is worse than none); growing
   the rule table is the incremental follow-up.
4. ~~**Balance is a point-in-time stamp.**~~ **DONE** — `balance_after` is now a
   persisted column (migration `2026060102`), backfilled on re-import via the
   confirm upsert. `GET /api/imports/continuity` chains every stored statement
   per account and reports likely-missing months across the WHOLE history (not
   just one batch); surfaced as a "Statement coverage" panel in Import Cleanup.
   The in-batch confirm-time warning (`services/continuity.rs`) still fires too.
   Balance-over-time charting is now derivable from the stored column (not yet
   built).
5. **5 banks now** (Banamex, BBVA, Santander, Nu, CetesDirecto). Adding a
   bank = a new layout parser; the architecture makes this incremental.
   **Caveat:** the BBVA + Santander parsers were built and unit-tested
   against `pdftotext -layout` fixtures *reconstructed from real
   transparency-portal statements* (the personal-account description
   vocabulary is plausible, not lifted from a confirmed personal PDF).
   Validate column geometry + sign bucketing against a real personal
   statement when one is available before fully trusting them.
6. **OCR confidence** — ~~a misread amount/date imports silently~~ rows whose
   text came from OCR are now flagged: `ParsedTransaction.from_ocr` is set in
   `detect_and_parse` when OCR was used, and the preview shows an "OCR — verify"
   badge so the user eyeballs those rows. Still coarse (per-document, not
   per-word tesseract confidence) — that refinement remains open.

---

## Backlog — prioritized (impact-per-effort)

### 1. Import the secondary (savings/Pagaré) account as its own account  ★ high — ✅ SHIPPED
`banamex_layout` now splits a bundled statement at each "SALDO ANTERIOR"
opener and parses **every** account section (resetting the running balance
per section), tagging secondary rows with `ParsedTransaction.account_label`
(stable ordinal "Cuenta secundaria"). The preview groups by label and
`import_screen.dart` shows a destination-account picker per section
(+ inline create); confirm fires one call per destination account. No
cross-account dedup needed — each account legitimately records its own side
of a transfer. Tests: `parses_both_accounts_and_labels_the_secondary`.
**Remaining:** validate secondary-section row fidelity against a real
multi-account statement (the delta parser can misread sparse savings rows —
the preview is the guard); a friendlier auto-derived label than the ordinal.

### 2. Auto-categorize imported transactions  ★ high — ✅ SHIPPED
`services/categorize.rs`: rule pass (Spanish merchant/keyword + amount sign)
→ Plaid PFC primary code, reusing the `category.dart` taxonomy. Wired into
`polish_all` (parse time → preview chip + round-trip) with a confirm-time
safety net. Tests in `categorize.rs` + `parser/tests.rs`.
**Follow-ups SHIPPED:** the merchant rule table was grown substantially
(fuel, telecom, grocers, streaming, SaaS, marketplaces); and **learn-from-
edits** — at confirm, the user's manually-set `user_category` is mapped by a
coarse `merchant_key` and carried onto matching new imports (`imports.rs` +
`categorize::merchant_key`). **Still open:** a balance-anchored content hash;
per-word OCR confidence.

### 3. Statement continuity / gap detection  ★ medium — ✅ SHIPPED (in-batch)
`services/continuity.rs`: at confirm time, groups the imported rows by
statement file, derives each statement's opening/closing from the running
`balance_after`, sorts by period, and flags a balance discontinuity between
sequential statements (a likely missing month). Returned as `warnings` in the
confirm response; `import_screen.dart` shows them in a dialog. Tests cover
missing-middle, clean-chain, out-of-order, duplicate-overlap, and
no-balance cases.
**Remaining:** this is **in-batch** (checks only what's in one confirm) and
advisory. A full-history check would need a persisted `balance_after` column
on `transactions` + a `/imports/continuity` endpoint over stored data.

### 4. Harden the dedup signature  ★ medium — ✅ SHIPPED (occurrence index)
`imports.rs::batch_signatures` adds a per-(date,amount,desc) occurrence
index: the 2nd+ exact duplicate in a batch gets a `#N` suffix so distinct
same-day/same-amount/same-desc rows survive, while the first keeps the bare
legacy signature (already-imported history still dedups, re-imports stay
idempotent). Shared by check-duplicates (preview) + confirm. Tests in
`imports.rs`.
**Remaining:** re-import-on-description-drift (a row whose description parses
slightly differently across parser versions gets a new signature → re-imports
as a new row); dedup vs Plaid-synced rows. A balance-anchored content hash
(date+amount+balance_after) would address the drift case.

### 5. More banks  ★ medium, incremental — BBVA + Santander SHIPPED
**Done:** `bbva_layout.rs` + `santander_layout.rs` (+ shared `layout_util.rs`),
routed by content signature, unit-tested against reconstructed-from-real
fixtures. **Nu PDF** (`nu_mexico_pdf.rs`) is now a real column parser too:
the prior stub was replaced (it hardcoded the current year + had a no-op
sign TODO). It reads the Cuenta statement's signed `Monto` + running
`$Saldo`, takes the sign from the balance delta (keyword fallback), and
takes the year from the `Periodo` header; routing tries it over the
pdftotext `-layout` text first, lopdf as fallback. **Remaining:** HSBC,
Banorte, Scotiabank. Same shape as the layout parsers. **Highest priority
within this item:** validate BBVA + Santander + Nu against a real *personal*
statement (current fixtures use plausible personal-account description
vocab — see Known-limitation #5).

### 6. OCR confidence + review flagging  ★ low — ✅ SHIPPED (coarse)
OCR-sourced rows are flagged for review: `from_ocr` is set when
`detect_and_parse` used OCR, and the preview shows an "OCR — verify" badge.
**Remaining (the original finer-grained idea):** per-word tesseract
confidence (TSV) to flag only the genuinely low-confidence rows.
<!-- original scope below -->
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
