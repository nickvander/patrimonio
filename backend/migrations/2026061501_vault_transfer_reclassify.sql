-- Backfill: reclassify SoFi "vault" moves that Plaid mislabeled as income.
-- SoFi exposes several "Vault" sub-accounts (Cards, Car, Rent, Mxn trade,
-- Taxes, Emergency) as the user's own `cash management` accounts. Moving
-- money between a vault and SoFi Checking produces a Plaid transaction with a
-- descriptor like "From Cards Vault" / "To Mxn trade Vault" — but Plaid tags
-- it personal_finance_category.detailed = INCOME_CONTRACTOR (primary INCOME).
-- These are INTERNAL TRANSFERS, not income, so they must not count toward
-- income/spend. sync.rs::upsert_plaid_transaction now overrides the category
-- on ingest (is_vault_transfer); this fixes the rows already stored.
--
-- Direction follows the app's sign convention (positive = inflow):
--   amount >= 0 -> TRANSFER_IN  / TRANSFER_IN_ACCOUNT_TRANSFER
--   amount <  0 -> TRANSFER_OUT / TRANSFER_OUT_ACCOUNT_TRANSFER
-- The descriptor lives in `description` (bound from Plaid's `name`).
UPDATE transactions
SET category = CASE WHEN amount >= 0 THEN 'TRANSFER_IN' ELSE 'TRANSFER_OUT' END,
    category_detailed = CASE WHEN amount >= 0 THEN 'TRANSFER_IN_ACCOUNT_TRANSFER' ELSE 'TRANSFER_OUT_ACCOUNT_TRANSFER' END
WHERE description ~* '^(from|to)\s+.+\svault$';
