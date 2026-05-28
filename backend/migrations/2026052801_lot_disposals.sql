-- Realized P&L audit trail for security sells.
--
-- The lot-tracking feature (holding_lots) records buys at FX-aware
-- historical cost. Sells FIFO-deplete those lots in place, which
-- gives us a correct *unrealized* P&L on what's left but loses the
-- *realized* P&L (the gain or loss the user actually crystallised at
-- the moment of sale). This table captures one row per (sell event,
-- depleted lot) pair so the realized history is durable across
-- re-syncs.
--
-- One sell can deplete multiple lots when the sold quantity spans
-- more than one acquisition tranche — that's why the unique key
-- includes lot_id rather than just sell_source_id.
--
-- A re-sync of the same investment transaction must not double-
-- insert disposals; the partial unique index on
-- (user_id, sell_source_id, lot_id) prevents that. The sell-marker
-- row in holding_lots already short-circuits the depletion loop
-- itself, so this is belt-and-braces.

CREATE TABLE IF NOT EXISTS lot_disposals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    holding_id UUID NOT NULL REFERENCES holdings(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    -- The lot this disposal consumed from. Nullable because the
    -- original lot row may be later deleted (manual cleanup,
    -- ON DELETE CASCADE elsewhere) — we keep the audit row.
    lot_id UUID REFERENCES holding_lots(id) ON DELETE SET NULL,
    -- The Plaid investment-tx id (or other source id) of the sell
    -- event itself. Used by the unique index for idempotency.
    sell_source_id TEXT NOT NULL,
    -- Quantity sold OUT OF THIS LOT (not the whole sell event).
    qty_sold NUMERIC(20, 8) NOT NULL CHECK (qty_sold > 0),
    -- Sale-side numbers (native currency).
    sell_price_per_unit NUMERIC(20, 8) NOT NULL,
    sell_currency TEXT NOT NULL,
    sell_fx_rate NUMERIC(20, 8) NOT NULL,
    sell_date DATE NOT NULL,
    -- Cost-side numbers (snapshotted from the depleted lot — these
    -- are the values that would have aged out of holding_lots if the
    -- lot row gets deleted later).
    cost_per_unit NUMERIC(20, 8) NOT NULL,
    cost_fx_rate NUMERIC(20, 8) NOT NULL,
    -- Pre-computed so the holdings endpoint doesn't need to redo the
    -- arithmetic on every read. Negative = loss.
    realized_pnl_usd NUMERIC(20, 6) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_lot_disposals_dedup
    ON lot_disposals (user_id, sell_source_id, lot_id);
CREATE INDEX IF NOT EXISTS idx_lot_disposals_user_holding
    ON lot_disposals (user_id, holding_id, sell_date DESC);
