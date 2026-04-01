-- Add crypto-specific metadata to accounts table
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS ticker_symbol VARCHAR(10);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS crypto_amount DECIMAL(24, 8);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS coinbase_account_id VARCHAR(100);

-- Update the account_type to handle 'crypto' if not already present
-- (Already handled by standard VARCHAR, but good to note)
