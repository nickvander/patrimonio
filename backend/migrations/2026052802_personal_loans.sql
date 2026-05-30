-- Personal lending module (opt-in per user via app_settings
-- 'lending_enabled'). The user lends money to a named borrower; the
-- disbursement is a real bank outflow transaction, each repayment is a
-- real inflow transaction, reconciled (manually or via auto-suggest)
-- against those rows.
--
-- Design notes:
--   * Modeled on the GnuCash "receivable" approach — the outstanding
--     balance is DERIVED (principal + accrued interest − Σ repayments),
--     never stored, so it can't drift out of sync with the linked
--     transactions.
--   * Transaction links (disbursement_tx_id, actual_tx_id) are
--     ON DELETE SET NULL, NOT CASCADE: unlike cash_fx_transfers where
--     the link IS the row, a loan/installment is a durable concept that
--     should survive a deleted bank transaction (matches
--     lot_disposals.lot_id). A Plaid TRANSACTIONS_REMOVED webhook
--     clears the link but leaves the loan intact.
--   * Loan-linked transactions are excluded from the cash-flow view
--     (lending isn't spending; repayment isn't income) via NOT EXISTS
--     against these two columns in cash_flow_trends — the partial
--     unique indexes below make those anti-joins index-only probes.

-- Reusable borrower directory. Personal lending has no global
-- counterparty table, so each user keeps their own small list of
-- people they've lent to — repeat loans autocomplete and we can show
-- total-lent-per-person.
CREATE TABLE IF NOT EXISTS people (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    -- Optional free-form contact note (phone, email, "cousin").
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One person per (user, case-insensitive name) so "Jose" typed twice
-- reuses the same row instead of stacking duplicates.
CREATE UNIQUE INDEX IF NOT EXISTS idx_people_user_name
    ON people (user_id, LOWER(name));

CREATE TABLE IF NOT EXISTS loans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Borrower. person_id links the reusable directory; borrower_name
    -- is denormalized so a loan still renders if the person row is
    -- later deleted, and so the auto-suggest name-matching has the
    -- string without a join.
    person_id UUID REFERENCES people(id) ON DELETE SET NULL,
    borrower_name TEXT NOT NULL,
    principal NUMERIC(20, 6) NOT NULL CHECK (principal > 0),
    currency TEXT NOT NULL,
    -- Annual rate as a fraction (0.075 = 7.5%). 0 = interest-free.
    interest_rate NUMERIC(9, 6) NOT NULL DEFAULT 0 CHECK (interest_rate >= 0),
    -- 'none' | 'simple' | 'amortized'. MVP ships none + simple;
    -- amortized is v2 (the schedule generator).
    interest_type TEXT NOT NULL DEFAULT 'none'
        CHECK (interest_type IN ('none', 'simple', 'amortized')),
    origination_date DATE NOT NULL,
    -- Schedule config. Both nullable for open-ended / on-demand loans
    -- with no fixed plan.
    term_months INT CHECK (term_months IS NULL OR term_months > 0),
    payment_frequency TEXT
        CHECK (payment_frequency IS NULL
               OR payment_frequency IN ('monthly', 'weekly', 'lump_sum')),
    -- The disbursement leg: the bank outflow that funded the loan.
    -- Nullable until reconciled.
    disbursement_tx_id UUID REFERENCES transactions(id) ON DELETE SET NULL,
    -- 'active' | 'paid_off' | 'written_off' | 'cancelled'.
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paid_off', 'written_off', 'cancelled')),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_loans_user
    ON loans (user_id, origination_date DESC);
CREATE INDEX IF NOT EXISTS idx_loans_person
    ON loans (person_id) WHERE person_id IS NOT NULL;
-- One loan per disbursement tx — re-running reconcile is idempotent and
-- a single bank outflow can't fund two loans. Partial so the many
-- not-yet-reconciled loans don't collide on NULL. Also serves the
-- cash-flow-exclusion anti-join.
CREATE UNIQUE INDEX IF NOT EXISTS idx_loans_disbursement_tx
    ON loans (disbursement_tx_id) WHERE disbursement_tx_id IS NOT NULL;

-- One row per repayment. In MVP these are created on reconciliation
-- (link a real inflow + record paid amount/date); the v2 amortization
-- generator will pre-create scheduled rows with actual_tx_id NULL.
CREATE TABLE IF NOT EXISTS loan_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    loan_id UUID NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
    -- 1-based position. For unscheduled MVP repayments this is just an
    -- incrementing sequence per loan; the unique index keeps regen
    -- idempotent once the v2 schedule generator lands.
    installment_number INT NOT NULL CHECK (installment_number >= 1),
    due_date DATE,
    scheduled_amount NUMERIC(20, 6) NOT NULL DEFAULT 0 CHECK (scheduled_amount >= 0),
    scheduled_principal NUMERIC(20, 6) NOT NULL DEFAULT 0,
    scheduled_interest  NUMERIC(20, 6) NOT NULL DEFAULT 0,
    -- Actuals, filled on reconciliation. NULL until a real inflow tx is
    -- linked. CASCADE-safe via SET NULL: deleting the tx clears the
    -- link but leaves the installment.
    actual_tx_id UUID REFERENCES transactions(id) ON DELETE SET NULL,
    paid_amount NUMERIC(20, 6),
    paid_date DATE,
    -- 'scheduled' | 'paid' | 'partial' | 'late' | 'skipped'.
    status TEXT NOT NULL DEFAULT 'scheduled'
        CHECK (status IN ('scheduled', 'paid', 'partial', 'late', 'skipped')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- A reconciled payment must record what was actually paid.
    CHECK (actual_tx_id IS NULL OR paid_amount IS NOT NULL)
);

-- Idempotent schedule regeneration: upsert on (loan_id, installment_number).
CREATE UNIQUE INDEX IF NOT EXISTS idx_loan_payments_installment
    ON loan_payments (loan_id, installment_number);
CREATE INDEX IF NOT EXISTS idx_loan_payments_user
    ON loan_payments (user_id, due_date);
CREATE INDEX IF NOT EXISTS idx_loan_payments_loan
    ON loan_payments (loan_id);
-- One installment per real inflow tx — prevents linking the same
-- repayment twice. Partial over the unreconciled NULLs. Also serves
-- the cash-flow-exclusion anti-join.
CREATE UNIQUE INDEX IF NOT EXISTS idx_loan_payments_actual_tx
    ON loan_payments (actual_tx_id) WHERE actual_tx_id IS NOT NULL;
