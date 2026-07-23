-- Unified notifications center: turn user_notifications (created by the
-- FX-center migration) into a real inbox.
--
-- Additive-only extension:
--
-- * dedupe_key — stable identity for generated-on-read notifications
--   (loan payment due reminders are inserted lazily when the inbox is
--   listed; the unique partial index makes that insert idempotent, so a
--   reminder that was already emitted — and possibly already read —
--   isn't re-created as a fresh unread row on every GET).
-- * link_kind / link_id — optional deep-link subject ("loan" + loan id,
--   …) so the frontend can jump from a notification to the thing it is
--   about without parsing the human-readable title/body.
--
-- Existing writers (fx_alert, import_stale) keep inserting with these
-- columns NULL; their deep links are derived from `kind` alone.

ALTER TABLE user_notifications
    ADD COLUMN IF NOT EXISTS dedupe_key TEXT,
    ADD COLUMN IF NOT EXISTS link_kind TEXT,
    ADD COLUMN IF NOT EXISTS link_id TEXT;

-- Idempotency for generated-on-read inserts (ON CONFLICT target).
-- Partial: event-style rows (fx_alert crossings) legitimately repeat and
-- carry no dedupe key.
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_notifications_dedupe
    ON user_notifications(user_id, dedupe_key)
    WHERE dedupe_key IS NOT NULL;

-- The bell badge is "my unread count" — index exactly that access path.
CREATE INDEX IF NOT EXISTS idx_user_notifications_unread
    ON user_notifications(user_id)
    WHERE read_at IS NULL;
