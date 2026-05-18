-- Per-user scope for app_settings (M7 leftover).
--
-- The original `app_settings` table was a single-row-per-key global
-- store. That was fine when the app was strictly single-user, but
-- once invitation-based registration shipped (2026051707_invite_tokens),
-- any second user redeeming an invite would silently share the first
-- user's budgets / net-worth goals / dismiss states.
--
-- Migration plan:
--   1. Add nullable `user_id` column.
--   2. Backfill every existing row to the SINGLE existing user. If
--      multiple users already exist by the time this lands (race
--      between bootstrap and first invite), the backfill leaves all
--      rows on the bootstrap user — the alternative is splitting
--      arbitrary keys, which would be worse.
--   3. Make `user_id` NOT NULL.
--   4. Replace the (key) primary key with (user_id, key).

ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS user_id UUID
        REFERENCES users(id) ON DELETE CASCADE;

-- Backfill: every existing row belongs to the bootstrap user (the
-- one with the earliest created_at). With only one user this is the
-- single existing row; with multiple users you lose isolation on
-- rows that were created before this migration, but you're moving
-- forward with proper isolation.
UPDATE app_settings SET user_id = (
    SELECT id FROM users ORDER BY created_at ASC LIMIT 1
)
WHERE user_id IS NULL;

ALTER TABLE app_settings ALTER COLUMN user_id SET NOT NULL;

ALTER TABLE app_settings DROP CONSTRAINT IF EXISTS app_settings_pkey;
ALTER TABLE app_settings ADD PRIMARY KEY (user_id, key);
