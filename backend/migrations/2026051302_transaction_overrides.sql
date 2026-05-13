-- Add data quality and customization fields to transactions
ALTER TABLE transactions 
ADD COLUMN IF NOT EXISTS user_category TEXT,
ADD COLUMN IF NOT EXISTS user_notes TEXT,
ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'plaid',
ADD COLUMN IF NOT EXISTS source_id TEXT;

-- Update existing transactions to have a default source
UPDATE transactions SET source = 'plaid' WHERE source IS NULL;

-- Add index for source-based queries
CREATE INDEX IF NOT EXISTS idx_transactions_source ON transactions(source);
