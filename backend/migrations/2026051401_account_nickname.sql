-- Add a user-defined nickname for an account. When set, the UI shows
-- this in place of the bank-supplied `name` so users can override
-- ugly defaults like "PLAID CHECKING 0001". Plaid syncs only write
-- the bank's `name` and never touch this column, so renames survive
-- re-sync.
ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS nickname TEXT;
