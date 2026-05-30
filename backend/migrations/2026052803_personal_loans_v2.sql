-- Personal lending Phase 2: amortization schedules + write-off/default.
--
-- The only schema change is adding 'defaulted' to the loans.status
-- CHECK. Everything else Phase 2 needs already exists on
-- loan_payments (scheduled_principal / scheduled_interest / due_date /
-- status), and the presence of loan_payments rows with
-- scheduled_amount > 0 IS the "schedule has been generated" signal —
-- so no nullable schedule_generated_at column that could desync from
-- the rows.
--
-- Status semantics:
--   active      — normal; outstanding derived from the schedule.
--   paid_off    — fully repaid (auto-set when outstanding <= 0.01).
--   defaulted   — borrower stopped paying; debt still real + flagged;
--                 outstanding stays derived and still counts in totals.
--   written_off — lender forgave it; outstanding forced to 0, excluded
--                 from totals.
--   cancelled   — data error / loan never happened; outstanding 0.

ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_status_check;
ALTER TABLE loans ADD CONSTRAINT loans_status_check
    CHECK (status IN ('active', 'paid_off', 'written_off', 'cancelled', 'defaulted'));
