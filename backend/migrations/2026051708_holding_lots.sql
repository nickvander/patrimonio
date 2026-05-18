-- FX-aware cost-basis lot tracking (per FUTURE.md item 2).
--
-- Holdings today carry a flat `cost_basis` in the security's native
-- currency. For a bi-national USD/MXN investor that's a problem:
--
--   * MXN P&L can't be derived from USD cost_basis + current FX —
--     the lot was acquired at one FX rate and is being valued at
--     another, so MXN gain isn't a function of USD gain alone.
--   * Multi-acquisition lots (DCA over time) collapse to a single
--     average, which loses the per-buy FX context.
--
-- This table stores each acquisition event individually. On a `sell`
-- the sync engine FIFO-depletes lots and writes the realized P&L
-- back to the holdings row. Today's schema is forward-compatible:
-- existing holdings keep their flat `cost_basis` until lots get
-- populated by a future Plaid `/investments/transactions/get` sync
-- pass — until then the read API falls back to the flat value.
--
-- `usd_fx_rate` is the USD/MXN rate at acquisition time. We pin USD
-- as the canonical pivot so a holding in any currency can be
-- expressed in any other through one conversion. For a USD security
-- the rate is 1.0; for an MXN security it's the historical USDMXN
-- on that date.
CREATE TABLE IF NOT EXISTS holding_lots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    holding_id UUID NOT NULL REFERENCES holdings(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    acquired_at DATE NOT NULL,
    qty NUMERIC(20, 8) NOT NULL,
    cost_per_unit NUMERIC(20, 8) NOT NULL,
    currency TEXT NOT NULL,
    -- USD/MXN at acquisition (or whatever the canonical pivot is for
    -- the security's native currency). 1.0 when the security is USD.
    usd_fx_rate NUMERIC(20, 8) NOT NULL DEFAULT 1.0,
    -- Source identifier from the upstream feed (Plaid transaction_id,
    -- broker confirmation, etc.) for idempotent re-sync.
    source_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_holding_lots_user
    ON holding_lots (user_id, holding_id, acquired_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_holding_lots_source
    ON holding_lots (holding_id, source_id)
    WHERE source_id IS NOT NULL;
