-- Two-step login support: when a user has TOTP enabled, the password
-- step issues a short-lived "pending" session. The TOTP verify
-- endpoint reads the pending cookie, validates the code, then rotates
-- to a full long-lived session.
--
-- require_auth middleware refuses any request carrying a pending
-- session, so a half-authenticated cookie can't reach data routes.

ALTER TABLE user_sessions
    ADD COLUMN pending_totp BOOLEAN NOT NULL DEFAULT false;
