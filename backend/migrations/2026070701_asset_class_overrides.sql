-- Round 3: user override of the heuristic asset classification (classify_asset).
-- Keyed per (user, symbol) — NOT a holdings column — because import/sync churns
-- holdings rows (delete+reinsert) and a classification is a property of the
-- instrument, not of one account's row. Strictly additive.
CREATE TABLE IF NOT EXISTS asset_class_overrides (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    symbol      TEXT NOT NULL,
    asset_class TEXT NOT NULL CHECK (asset_class IN
        ('equity','bonds','cash','crypto','real_estate','commodities','other')),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, symbol)
);
