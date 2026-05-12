-- Make external syncs idempotent enough for repeated real-account refreshes.

ALTER TABLE institutions ADD COLUMN IF NOT EXISTS plaid_transactions_cursor TEXT;

ALTER TABLE holdings ADD COLUMN IF NOT EXISTS external_id TEXT;

CREATE INDEX IF NOT EXISTS idx_accounts_external_id ON accounts(external_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_holdings_account_external_id
    ON holdings(account_id, external_id)
    WHERE external_id IS NOT NULL;
