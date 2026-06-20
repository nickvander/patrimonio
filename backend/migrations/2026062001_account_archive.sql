-- Reversible auto-archive of accounts Plaid (or any aggregator) no longer
-- returns: a closed/removed account at the bank — e.g. a deleted SoFi vault.
-- Plaid's /accounts (+ balance) returns only currently-OPEN accounts, so the
-- sync reconciles the now-missing ones by stamping archived_at instead of
-- hard-deleting: the row + its transactions survive and the account can be
-- restored (archived_at = NULL) if it reappears or the user un-archives it.
--
-- NULL = active. Non-NULL = archived (excluded from net worth, balances,
-- lists, and every aggregate the user browses).
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

-- The display/aggregate queries all filter `user_id = $1 AND archived_at IS
-- NULL`; a partial index over the active rows keeps those scans tight without
-- carrying the (rare) archived rows in the index.
CREATE INDEX IF NOT EXISTS idx_accounts_user_active
    ON accounts (user_id)
    WHERE archived_at IS NULL;
