-- "Never re-suggest this FX pair." Closes the long-standing gap in
-- `cash_fx_transfers`: unlinking a row removed the link from the
-- detected-pairs table, but the detector's next run would happily
-- re-propose the same pair. Each unlink now also lands a row here;
-- the detector consults this table before inserting.
--
-- Keyed on (user_id, source_tx_id, dest_tx_id). The detector tries
-- a pair in only one direction (outflow→inflow), so a single row
-- per "this two-tx combination" is enough. If the user later
-- re-confirms via the Hidden Items screen we DELETE the row and
-- the next detector run is free to surface it again.
--
-- FK CASCADEs match `cash_fx_transfers`: if either underlying
-- transaction is deleted (manual cleanup, Plaid TRANSACTIONS_REMOVED
-- webhook, etc.) the dismissal silently goes with it — keeps the
-- table from holding rows that point at nothing.

CREATE TABLE IF NOT EXISTS dismissed_fx_pairs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source_tx_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    dest_tx_id   UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    dismissed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (source_tx_id <> dest_tx_id),
    UNIQUE (user_id, source_tx_id, dest_tx_id)
);

CREATE INDEX IF NOT EXISTS idx_dismissed_fx_pairs_user
    ON dismissed_fx_pairs (user_id, dismissed_at DESC);
CREATE INDEX IF NOT EXISTS idx_dismissed_fx_pairs_source ON dismissed_fx_pairs (source_tx_id);
CREATE INDEX IF NOT EXISTS idx_dismissed_fx_pairs_dest   ON dismissed_fx_pairs (dest_tx_id);
