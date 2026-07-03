-- CUSTOM, explicit-row payment schedules.
--
-- 'custom' loans have arbitrary {due_date, amount} installments that no
-- formula produces (e.g. a 0% loan whose N payments sum to principal,
-- with a one-off bump). The rows are uploaded explicitly via
-- POST /{id}/schedule/custom, not regenerated from terms.
ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_interest_type_check;
ALTER TABLE loans ADD CONSTRAINT loans_interest_type_check
    CHECK (interest_type IN ('none', 'simple', 'amortized', 'interest_only', 'compound', 'custom'));
