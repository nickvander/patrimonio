-- Interest-income accounting: record the principal vs interest split
-- on each reconciled repayment.
--
-- Why store (not derive): cash-basis interest income is a point-in-time
-- fact tied to the outstanding balance + rate AS OF the payment date.
-- Recomputing later from a (possibly regenerated) schedule would drift
-- and lose the audit trail. We store the split at reconciliation time,
-- mirroring GnuCash's split-per-transaction model, so the year-end
-- interest-income report is a trivial SUM.
--
--   principal_portion — return of capital (NOT income)
--   interest_portion  — interest earned (taxable income, cash basis)
--   balance_after     — outstanding principal after this payment
--
-- All nullable: only reconciled rows (actual_tx_id set) carry a split.
ALTER TABLE loan_payments
    ADD COLUMN IF NOT EXISTS principal_portion NUMERIC(20, 6),
    ADD COLUMN IF NOT EXISTS interest_portion  NUMERIC(20, 6),
    ADD COLUMN IF NOT EXISTS balance_after      NUMERIC(20, 6);

-- Cash-basis interest income is summed by paid_date; index the rows
-- that actually carry interest so the per-year report is a cheap scan.
CREATE INDEX IF NOT EXISTS idx_loan_payments_interest
    ON loan_payments (user_id, paid_date)
    WHERE interest_portion IS NOT NULL;
