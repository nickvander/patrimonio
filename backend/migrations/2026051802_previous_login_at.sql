-- Track the prior session anchor so the dashboard can answer "what's
-- new since you were last here." `last_login_at` is bumped on every
-- successful login; without a prior anchor we'd be comparing against
-- "right now" and the diff would always be zero.
--
-- The update sites (password login, passkey login, TOTP confirm) copy
-- the current `last_login_at` into `previous_login_at` BEFORE setting
-- `last_login_at = NOW()`, so this column tracks the second-most-recent
-- successful login. Seed existing rows from their current
-- `last_login_at` so the first "since last login" lookup returns "0
-- new things" rather than "everything ever" on a freshly-deployed
-- backend.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS previous_login_at TIMESTAMPTZ;

UPDATE users
SET previous_login_at = last_login_at
WHERE previous_login_at IS NULL;
