-- Per-user "this merchant isn't actually a subscription" blocklist.
--
-- The recurring-charge detector is heuristic — a clustered set of
-- Amazon orders that happens to fall within the 5–62 day cadence
-- window can look like a subscription. The user can dismiss those
-- false positives with one click, which lands a row here, and the
-- detector skips matching keys on subsequent runs.
--
-- merchant_key is the same case-folded label the detector uses for
-- clustering (display_merchant lowercased + trimmed). Storing it as
-- the matched key means a future detector tweak that changes
-- clustering keys would invalidate ignore entries — that's the
-- correct behavior (the user dismissed a specific pattern; if the
-- pattern definition changes, they should re-confirm).
CREATE TABLE IF NOT EXISTS ignored_subscription_merchants (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    merchant_key TEXT NOT NULL,
    ignored_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, merchant_key)
);
