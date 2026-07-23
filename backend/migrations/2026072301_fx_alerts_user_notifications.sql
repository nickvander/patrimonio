-- Interactive FX center: per-user rate-alert thresholds + a generic
-- user_notifications store.
--
-- user_fx_alerts holds one threshold per (user, pair) — the FX center UI
-- exposes a single "notify me when the rate crosses X" value, so the
-- UNIQUE constraint makes the PUT endpoint a simple upsert.
--
-- user_notifications is deliberately generic (kind/title/body/read_at):
-- the upcoming notifications-center feature will surface these rows in
-- the bell, so nothing FX-specific leaks into the schema. FX crossings
-- write kind='fx_alert'.

CREATE TABLE IF NOT EXISTS user_fx_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    base_currency TEXT NOT NULL,
    target_currency TEXT NOT NULL,
    -- Same precision as exchange_rates.rate so threshold comparisons
    -- never lose digits against a stored rate.
    threshold NUMERIC(15, 8) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Stamped when a crossing notification is recorded; purely
    -- informational (crossing detection itself is edge-triggered off
    -- consecutive rates, so it self-debounces).
    last_notified_at TIMESTAMPTZ,
    UNIQUE (user_id, base_currency, target_currency)
);

CREATE TABLE IF NOT EXISTS user_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at TIMESTAMPTZ
);

-- The bell will read "my newest notifications" — index for that access path.
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_created
    ON user_notifications(user_id, created_at DESC);
