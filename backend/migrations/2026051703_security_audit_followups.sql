-- Security + performance audit follow-ups.
--
-- 1. TOTP replay protection
--    Track the last TOTP step the user already consumed so a captured
--    6-digit code can't be reused inside its ~90-second window.
--    `totp::verify` will reject any code whose step is <= last_step.
ALTER TABLE users
ADD COLUMN totp_last_used_step BIGINT;

-- 2. Global transactions feed needs an index for the unfiltered
--    ORDER BY date DESC, created_at DESC path used by /api/dashboard.
--    Without this the dashboard does a heap scan + sort over the
--    whole table.
CREATE INDEX IF NOT EXISTS idx_transactions_date_global
ON transactions (date DESC, created_at DESC);

-- 3. Passkey lookup by (user_id, credential_id) happens on every
--    login_finish; backstop it with a composite index. Helps even
--    after the existing UNIQUE (credential_id) because the WHERE in
--    login_finish constrains both columns.
CREATE INDEX IF NOT EXISTS idx_passkey_credentials_user_cred
ON passkey_credentials (user_id, credential_id);
