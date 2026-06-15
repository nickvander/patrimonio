-- Backfill for the categorize.rs sign fix: a NEGATIVE amount can never be
-- INCOME (income is an inflow / positive). Statement-import rows like
-- "INTERESES AL %" for a negative amount — an interest charge, a
-- yield-liquidation withdrawal, or a reversal — were wrongly filed as INCOME
-- because the categorizer keyed on the word regardless of sign. Clear the
-- category on these definitionally-contradictory rows so they read as
-- uncategorized rather than asserting income; the user can recategorize.
--
-- Plaid income rows are always positive, so this only touches mislabeled
-- statement-import history. Idempotent.
UPDATE transactions
SET category = NULL,
    category_detailed = NULL
WHERE category = 'INCOME'
  AND amount < 0;
