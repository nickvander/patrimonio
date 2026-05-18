-- Invitation-based registration.
--
-- The bootstrap flow remains for the first user. After that, new
-- accounts can only be created by redeeming a one-time invite token
-- minted by an existing user. The plaintext token is shown ONCE at
-- mint time (in the admin's response and in the share URL); only its
-- SHA-256 hash is stored, so a DB snapshot leak can't be used to
-- redeem outstanding invites.
--
-- The redemption flow:
--   1. Admin POSTs /api/auth/invites → response includes
--      `token` (plaintext, ~43 chars) + `url` (login + ?invite=...)
--   2. Invitee opens the URL → login screen detects ?invite, shows
--      register form with username + password + confirm.
--   3. Frontend POSTs /api/auth/register {token, username, password}.
--   4. Backend SHA-256-hashes the token, finds the matching row
--      (and verifies expires_at > now() AND used_at IS NULL),
--      creates the user, stamps used_at + used_by_user_id.
--
-- The `role` column is forward-looking — `user` today, future values
-- could be `admin` / `read_only`. Not yet enforced; the column makes
-- the role column-shaped instead of NULL-shaped from day one.
CREATE TABLE IF NOT EXISTS invite_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash BYTEA NOT NULL UNIQUE,
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    used_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    role TEXT NOT NULL DEFAULT 'user',
    note TEXT
);

-- Filter by status (live / used / expired) cheaply.
CREATE INDEX IF NOT EXISTS idx_invite_tokens_status
    ON invite_tokens (used_at, expires_at)
    WHERE used_at IS NULL;
