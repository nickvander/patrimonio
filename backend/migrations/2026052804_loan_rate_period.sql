-- Personal lending Phase 3: flexible interest-rate period + interest-only.
--
-- rate_period lets the user say "1% per MONTH" and have it stored +
-- amortized faithfully, instead of forcing everything through an
-- annual figure and reconverting (which loses the user's intent). The
-- schedule generator reads this to decide the per-period rate:
--   annual  → monthly periodic = rate/12, weekly = rate/52  (existing)
--   monthly → the stored rate IS the monthly periodic rate; annualized
--             as rate*12 only where an annual figure is needed.
ALTER TABLE loans
    ADD COLUMN IF NOT EXISTS rate_period TEXT NOT NULL DEFAULT 'annual';
ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_rate_period_check;
ALTER TABLE loans ADD CONSTRAINT loans_rate_period_check
    CHECK (rate_period IN ('annual', 'monthly'));

-- New interest_type 'interest_only': each installment pays only the
-- period interest; the principal balloons on the final installment.
ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_interest_type_check;
ALTER TABLE loans ADD CONSTRAINT loans_interest_type_check
    CHECK (interest_type IN ('none', 'simple', 'amortized', 'interest_only'));
