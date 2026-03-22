-- Initial schema for Patrimonio
-- Creates all core tables for financial data tracking

-- Institutions the user has linked
CREATE TABLE institutions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    institution_type TEXT NOT NULL,
    country TEXT NOT NULL DEFAULT 'US',
    integration_type TEXT NOT NULL,
    plaid_access_token_enc BYTEA,
    plaid_item_id TEXT,
    last_synced_at TIMESTAMPTZ,
    sync_status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Individual accounts within an institution
CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    institution_id UUID NOT NULL REFERENCES institutions(id) ON DELETE CASCADE,
    external_id TEXT,
    name TEXT NOT NULL,
    account_type TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    current_balance DECIMAL(15,2),
    available_balance DECIMAL(15,2),
    credit_limit DECIMAL(15,2),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_accounts_institution ON accounts(institution_id);
CREATE INDEX idx_accounts_type ON accounts(account_type);

-- Daily balance snapshots for historical tracking
CREATE TABLE balance_snapshots (
    id BIGSERIAL PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    balance DECIMAL(15,2) NOT NULL,
    as_of_date DATE NOT NULL,
    currency TEXT NOT NULL,
    balance_usd DECIMAL(15,2),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(account_id, as_of_date)
);

CREATE INDEX idx_snapshots_account_date ON balance_snapshots(account_id, as_of_date);

-- Investment holdings
CREATE TABLE holdings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    symbol TEXT NOT NULL,
    name TEXT NOT NULL,
    quantity DECIMAL(18,8),
    price DECIMAL(15,4),
    value DECIMAL(15,2),
    cost_basis DECIMAL(15,2),
    currency TEXT NOT NULL DEFAULT 'USD',
    holding_type TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_holdings_account ON holdings(account_id);
CREATE INDEX idx_holdings_symbol ON holdings(symbol);

-- Exchange rates (historical)
CREATE TABLE exchange_rates (
    id BIGSERIAL PRIMARY KEY,
    base_currency TEXT NOT NULL,
    target_currency TEXT NOT NULL,
    rate DECIMAL(15,8) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    UNIQUE(base_currency, target_currency, recorded_at)
);

CREATE INDEX idx_fx_pair_time ON exchange_rates(base_currency, target_currency, recorded_at DESC);

-- Transactions
CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    external_id TEXT,
    date DATE NOT NULL,
    description TEXT NOT NULL,
    amount DECIMAL(15,2) NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    category TEXT,
    merchant_name TEXT,
    pending BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_transactions_account_date ON transactions(account_id, date DESC);
CREATE INDEX idx_transactions_category ON transactions(category);
