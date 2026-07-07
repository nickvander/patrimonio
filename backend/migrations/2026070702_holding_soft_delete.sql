-- Round 3: soft delete for holdings (undo window). NULL = live row.
-- holding_lots / lot_disposals get NO column: they are reachable only through
-- their holding; the FK ON DELETE CASCADE still performs the eventual hard purge.
-- Strictly additive: nullable column + partial index (mirrors accounts.archived_at,
-- migration 2026062001).
ALTER TABLE holdings ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_holdings_user_active
    ON holdings (user_id) WHERE deleted_at IS NULL;
