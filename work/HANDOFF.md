# Handoff — start here

> **Last updated:** 2026-06-03 (end of the statement-import deepening sprint)
> **Purpose:** The single "where are we, what's next" doc to pick up cold.
> For the full import architecture + backlog see
> [work/STATEMENT_IMPORT.md](STATEMENT_IMPORT.md); for the older broader
> backlog see [work/NEXT.md](NEXT.md) and [work/FUTURE.md](FUTURE.md).

## Where we are

All work below is **on `main` and pushed** (`origin/main` @ `d65a7f6`).
Everything verified green: backend `./scripts/test.sh` (100 lib unit +
72 dashboard integration + auth/passkey), `flutter analyze` clean, and
`flutter test` (148) — note Flutter must be run via docker, see the gotcha
at the bottom.

This sprint was a deep pass on **statement import**. Shipped, in order:

1. **BBVA + Santander parsers** (`bbva_layout.rs`, `santander_layout.rs`,
   shared `layout_util.rs`) — column-position bucketing; routed by content
   signature.
2. **Auto-categorization** (`services/categorize.rs`) — Spanish
   merchant/keyword + amount sign → Plaid PFC primary code, at parse time
   (preview chip + round-trip) with a confirm-time safety net.
3. **Multi-account (secondary) import** — `banamex_layout` splits a bundled
   statement at each `SALDO ANTERIOR` and parses every account section,
   tagging secondary rows with `account_label`; the import UI shows a
   destination picker per section. Banamex savings/Pagaré balance no longer
   dropped.
4. **Statement gap detection** (`services/continuity.rs`) — flags a likely
   missing month from a balance jump between sequential statements.
5. **Occurrence-aware dedup** (`imports.rs::batch_signatures`) — distinct
   identical rows no longer silently merge; first occurrence keeps the legacy
   bare signature so existing history still dedups.
6. **Real Nu México PDF parser** (`nu_mexico_pdf.rs`) — replaced the naive
   stub (current-year bug + no-op sign). Year from `Periodo`, sign from the
   balance delta, captures `balance_after`.
7. **Persisted `balance_after`** (migration `2026060102`) + **full-history
   continuity** (`GET /api/imports/continuity`) + a "Statement coverage"
   panel in Import Cleanup. Re-import backfills the column (confirm upsert).
8. **Smarter categorizer** — grew the rule table; **learn-from-edits**: the
   user's manual `user_category` is mapped by `merchant_key` and carried onto
   future imports of the same merchant.
9. **OCR review flag** — `ParsedTransaction.from_ocr`; preview shows an
   "OCR — verify" badge on scanned/photographed rows.

## Known caveats / things to validate (read before extending)

- **Fixtures, not real PDFs.** BBVA/Santander/Nu parsers + the Banamex
  secondary section were built and unit-tested against `pdftotext -layout`
  fixtures *reconstructed from real (mostly organizational) statements*. The
  personal-account description vocabulary is plausible, not confirmed.
  **Highest-value next QA step:** run a REAL personal BBVA/Santander/Nu or a
  multi-account Banamex statement through the importer and eyeball the
  preview (dates, debit/credit signs, closing balance). The preview is the
  live guard.
- **Continuity backfill is re-import-gated.** Rows imported before migration
  `2026060102` have NULL `balance_after`; re-importing a statement backfills
  it (dedup still skips re-inserting), but rows never re-imported stay null
  and are excluded from the full-history check.
- **Learn-from-edits is conservative.** Runs at confirm (after the preview),
  keys on the first ~3 significant words; won't catch every description
  variant. No new table — it queries the user's own labeled history.
- **OCR flag is coarse** (per-document, not per-word tesseract confidence).

## Suggested next steps (by value)

1. **Validate against real statements** (above) — cheapest way to de-risk the
   whole sprint; needs sample PDFs from the user.
2. **More banks**: Banorte, HSBC, Scotiabank — same pattern as
   BBVA/Santander (subagent research → column parser → fixture tests).
3. **Balance-over-time chart** — now derivable from the persisted
   `balance_after` column; no migration needed.
4. **Per-word OCR confidence** (tesseract TSV) to flag only genuinely
   low-confidence rows instead of the whole OCR'd file.
5. **Balance-anchored dedup hash** (date+amount+balance_after) to stop a
   description that parses slightly differently across versions re-importing.

## How to verify / ship (environment gotchas)

- Backend tests: `./scripts/test.sh` (dockerised toolchain; `cargo` isn't on
  the host). Migrations auto-apply to the test DB via `sqlx::migrate!`.
- **Flutter must run via docker** — host `flutter` fails writing a root-owned
  `frontend/.flutter-plugins-dependencies`:
  - analyze: `./scripts/check.sh --skip-backend`
  - test: `docker run --rm -v "$PWD/frontend":/app -w /app ghcr.io/cirruslabs/flutter:stable bash -lc 'flutter pub get >/dev/null 2>&1 && flutter test 2>&1'`
- Direct-push to `main` is gated by the Claude Code classifier; do the local
  `git merge --ff-only` + `git push origin main` (the user authorizes pushes).
