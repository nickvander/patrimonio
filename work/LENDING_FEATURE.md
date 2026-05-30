# Personal Lending module — design + phased plan

> **Status:** Phase 1 MVP SHIPPED (2026-05-29). Researched against
> GnuCash / YNAB / Copilot / Pigeon / Zirtue / Splitwise + mapped onto
> Patrimonio's existing patterns by subagents.
>
> **Decisions taken:** reusable people directory (not free-text);
> auto-suggest reconciliation (researched matcher + 23 test cases, O(window)
> performant); loan transactions excluded from cash flow.
>
> **Shipped in MVP:** migration `2026052802_personal_loans.sql` (people +
> loans + loan_payments); `services/loan_match.rs` (auto-suggest, 7 unit
> tests); `api/loans.rs` (CRUD + people + link disbursement +
> record/reconcile + suggestions + summary, owner-gated); cash-flow
> exclusion in `cash_flow_trends`; 6 integration tests; per-user
> `lending_enabled` toggle (Management tab) → conditional Lending tab;
> `widgets/lending_tab.dart` (loan list, add-loan w/ people autocomplete,
> detail sheet with auto-suggest confirm chips). 94 backend tests green.
>
> **Deferred to Phase 2/3** (see below): amortization schedule generation,
> reminders, written-off/defaulted UI, interest-only/balloon/compound,
> principal/interest split on repayments.

## What the user asked for

Track money they lend to friends: a transfer OUT from a bank account
(e.g. Banamex) is the **disbursement**; incoming payments are
**repayments**, reconciled against real transactions. Set interest +
a payment plan per loan. New **tab**, gated behind a **per-user toggle**
(not everyone wants the module).

## The model (from research)

The **GnuCash receivable model** is the template — it's the only
surveyed app that exactly matches "lend from a real bank account,
reconcile real bank transactions, split principal vs interest":

- The loan is a *receivable* whose outstanding balance is **derived,
  never stored**: `outstanding = principal + accrued_interest − Σ repayments`.
- Disbursement = the real bank outflow, linked as one leg.
- Each repayment = a real inflow transaction, linked + optionally split
  into principal/interest.
- **Reconciliation is manual-link-first** everywhere (YNAB transfers,
  Copilot's two-sided transfer). Auto-match by amount±tolerance/date is
  only a *suggestion* layer — don't over-invest in it for v1.
- **0% interest is the realistic default** between friends/family
  (Zirtue is built entirely on it) — interest is optional, not required.

### Interest formulas (when we get to them)
- **None:** `owed = principal − Σ repayments`. (MVP)
- **Simple:** `I = P·r·t`; total due `= P(1 + r·t)`. (MVP)
- **Amortizing:** `M = P·i(1+i)ⁿ / ((1+i)ⁿ − 1)`, `i = annual/12`, `n = months`.
  Per period: `interest_k = balance·i`, `principal_k = M − interest_k`. (v2)
- **Interest-only + balloon / compound:** (v3)

Worked check (GnuCash): $2,000 @ 5%/12 → M=$115.56 = $8.33 interest +
$107.23 principal → balance $1,892.77. Use this as a unit-test fixture.

## Backend shape (maps onto cash_fx_transfers + lot_disposals)

New migration **`backend/migrations/2026052802_personal_loans.sql`**:

- `loans(id, user_id, borrower_name, principal, currency, interest_rate,
  interest_type, origination_date, term_months, payment_frequency,
  disbursement_tx_id→transactions ON DELETE SET NULL, status, notes,
  created_at, updated_at)` — partial unique index on `disbursement_tx_id`
  (one loan per disbursement, idempotent reconcile).
- `loan_payments(id, user_id, loan_id→loans CASCADE, installment_number,
  due_date, scheduled_amount, scheduled_principal, scheduled_interest,
  actual_tx_id→transactions ON DELETE SET NULL, paid_amount, paid_date,
  status)` — unique `(loan_id, installment_number)` for idempotent
  schedule regen; partial unique on `actual_tx_id` (a repayment links to
  one installment only).

Convention notes: `NUMERIC(20,6)` money / `(20,8)` rates; tx FKs are
`ON DELETE SET NULL` (loan survives a deleted bank tx — unlike
cash_fx_transfers where the link *is* the row), matching
`lot_disposals.lot_id`.

New **`backend/src/api/loans.rs`** (`pub fn router()`), mounted in the
**business** router in `main.rs` (so `require_owner` gates mutations;
read-only invitees can view but not edit). Routes (static before
dynamic, per the matcher-order note in dashboard.rs):

```
GET    /api/loans                       list_loans
POST   /api/loans                       create_loan
GET    /api/loans/summary               loans_summary
GET    /api/loans/{id}                  get_loan
PATCH  /api/loans/{id}                  update_loan
DELETE /api/loans/{id}                  delete_loan
POST   /api/loans/{id}/disbursement     link_disbursement_tx
DELETE /api/loans/{id}/disbursement     unlink_disbursement_tx
POST   /api/loans/{id}/schedule         generate_schedule   (amortization, upsert)
GET    /api/loans/{id}/payments         list_loan_payments
POST   /api/loans/{id}/payments         record_payment      (manual/unscheduled)
PATCH  /api/loans/payments/{pid}        reconcile_payment   (link inflow tx + mark paid)
DELETE /api/loans/payments/{pid}        unreconcile_payment
```

Amortization lives in **`backend/src/services/loan_schedule.rs`**
(mirrors `services/fx_transfer_link.rs`). Every handler:
`Extension(ctx)`, `WHERE … user_id = $1`, verify a linked tx belongs to
the caller before writing (`SELECT 1 FROM transactions WHERE id=$1 AND
user_id=$2` → 404), publish `RealtimeEvent::TransactionsChanged` after
a committed reconcile/record/unlink (balances + cash-flow shift).

## Frontend shape

- **Toggle persists server-side** via the existing key/value store —
  `getSetting('lending_enabled')` / `putSetting('lending_enabled', bool)`
  already exist in `api_service.dart`. (localStorage `Preferences` would
  desync across devices — wrong for a tab-gating flag.)
- **Toggle UI**: a small "Modules" card in the **Management tab** (always
  reachable, already a settings-ish surface) — no new screen/route.
- **The tab gotcha**: tabs are declared in 3 lockstep places
  (`TabController(length: 7)` in initState; `TabBar.tabs`; `TabBarView.
  children`). `length` is set once before data loads. Fetch the setting
  in `_loadAllData`'s `Future.wait`, then in the setState block recreate
  the controller with `length: 7 + (_lendingEnabled ? 1 : 0)`, preserving
  the clamped index. Append "Lending" **last** (index 7) so existing
  `animateTo(6)` (→ Management) calls stay valid.

## Phased plan

**Phase 1 — MVP (build first):**
- Migration: `loans` + `loan_payments`.
- Backend: `loans.rs` CRUD + `link_disbursement_tx` + `record_payment` +
  `reconcile_payment` (link an existing imported tx). Interest types
  **none** + **simple** only. `loans_summary` (count, total lent, total
  outstanding). Integration tests (cross-tenant, reconcile idempotency).
- Settings: `lending_enabled` toggle read/write (reuse existing store).
- Frontend: Management-tab "Modules" card with the switch; conditional
  "Lending" tab; a LendingTab listing loans with outstanding balance,
  an "Add loan" dialog, a per-loan detail view that lets you designate
  an existing transaction as disbursement / repayment.

**Phase 2 — SHIPPED 2026-05-30:**
- ✅ Amortizing interest + generated schedule. `services/loan_schedule.rs`
  generates the installment rows in `Decimal` (never f64): amortized
  (level payment M with final-row residual absorption — `Σprincipal ==
  principal` to the cent), simple (flat equal split), none (equal
  principal). Frequencies monthly / weekly / lump_sum. 11 unit tests.
- ✅ `POST /loans/{id}/schedule` (re)generates; 409 if any payment is
  reconciled (regen would break the principal invariant), 422 if
  open-ended. Idempotent upsert on (loan_id, installment_number).
- ✅ Derived status logic in `LoanView`: `next_due`, `overdue`,
  `paid_ahead`, `total_scheduled`, `has_schedule`. Outstanding switches
  to `principal − Σ paid scheduled_principal` for scheduled loans;
  schedule-less loans keep the simple-interest path. `PaymentView`
  gains `scheduled_principal` / `scheduled_interest`.
- ✅ `record_payment` now FILLS the next unpaid scheduled installment
  (not append) when a generated schedule exists, so reconciliation
  drives the schedule-aware outstanding down correctly. MVP append
  behaviour preserved for open-ended loans.
- ✅ Migration `2026052803_personal_loans_v2.sql` adds `'defaulted'`
  status. Write-off / cancelled / paid_off force outstanding to 0;
  defaulted keeps it (flagged). Status set via `PATCH /loans/{id}`.
- ✅ Reminders: `GET /loans/reminders` returns upcoming + overdue
  installments (reading lead-days server-side from app_settings
  `lending_reminder_lead_days`, default 7). Surfaced in the existing
  notifications bell (overdue=red, upcoming=amber, tap → Lending tab).
  Configurable lead-time stepper in the Management Modules card.
- ✅ Auto-suggest repayment now uses the next unpaid installment's
  scheduled_amount (exact) instead of the principal/term approximation.
- ✅ Frontend: amortization schedule table + Generate/Regenerate
  button + status actions (mark defaulted / write off / reactivate) in
  the loan detail sheet.
- 6 Phase-2 integration tests (schedule sum, regen-refuse-409,
  open-ended-422, write-off/default outstanding, reminders
  upcoming/overdue/lead-days/exclusions, cross-tenant). Backend total
  now 100 tests.

**Phase 2 — deferred to Phase 3:** custom (irregular) schedule dates;
penalty interest on default.

**Phase 3 (power-user):**
- Interest-only + balloon, compound interest.
- Principal/interest split on each repayment + interest-income tracking.
- Promissory-note PDF export; multi-currency; re-amortization on
  irregular payment.

## Open questions for the user
1. Is the borrower just a free-text name, or do you want a reusable
   "people" list (so repeat loans to the same person autocomplete)?
2. For MVP, is **manual** "designate this transaction as a repayment"
   enough, or do you want auto-suggestions from day one?
3. Should an outgoing disbursement still count as an *expense* in the
   cash-flow view, or be excluded (it's not spending, it's a receivable)?
   GnuCash excludes it; recommend we exclude loan disbursements +
   repayments from cash-flow the same way transfers are excluded.
