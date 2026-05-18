-- Linked cross-currency cash transfers.
--
-- Why this exists: the lot-tracking feature (FX-aware cost basis on
-- investments) covers securities. It does NOT cover the bi-national
-- cash flow that's the user's daily reality:
--
--   US bank (USD)  →  Wise transfer (USD→MXN FX)  →  Nu Bank (MXN)
--
-- Today this is two unrelated rows: a USD outflow + an MXN inflow.
-- The implicit Wise FX rate is lost, the "USD cash on hand" balance
-- silently disappears, and "MXN cash on hand" silently appears with
-- no audit trail tying the two together.
--
-- This table records detected pairs. Detection is best-effort:
-- amount-amount ratio backs out a plausible USDMXN rate, a date
-- window of ±N days, and a remittance keyword on at least one side.
-- A `detection_confidence` score lets the UI distinguish auto-found
-- candidates from user-confirmed links — the user can confirm,
-- unlink, or ignore via the transaction detail modal.
--
-- The two tx columns are foreign-keyed with CASCADE so a tx delete
-- (manual cleanup or a Plaid TRANSACTIONS_REMOVED webhook) takes
-- the link with it — keeps us from orphaning links that point at
-- nothing.
--
-- A partial unique index on (source_tx_id, dest_tx_id) prevents
-- duplicate links for the same pair on repeat detection runs.

CREATE TABLE IF NOT EXISTS cash_fx_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source_tx_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    dest_tx_id   UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    source_amount NUMERIC(20, 6) NOT NULL,
    source_currency TEXT NOT NULL,
    dest_amount   NUMERIC(20, 6) NOT NULL,
    dest_currency TEXT NOT NULL,
    implied_fx_rate NUMERIC(20, 8) NOT NULL,
    -- 0..100. >= 70 = auto-confirmed; 40..69 = surfaced but awaits
    -- user confirm; < 40 = filtered out at detection time.
    detection_confidence SMALLINT NOT NULL,
    user_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- The keyword that triggered the match (WISE, REMITLY, etc.) —
    -- useful both for the UI and for tuning the detector later.
    matched_keyword TEXT,
    CHECK (source_tx_id <> dest_tx_id),
    CHECK (source_currency <> dest_currency)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_fx_pair
    ON cash_fx_transfers (source_tx_id, dest_tx_id);
CREATE INDEX IF NOT EXISTS idx_cash_fx_user
    ON cash_fx_transfers (user_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_fx_source ON cash_fx_transfers (source_tx_id);
CREATE INDEX IF NOT EXISTS idx_cash_fx_dest   ON cash_fx_transfers (dest_tx_id);
