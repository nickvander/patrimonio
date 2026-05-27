-- Multi-user roles: owner vs read-only.
--
-- Background: the multi-user data model shipped in
-- 2026051705_multi_user_ownership.sql gives every business row a
-- user_id and every read query filters on the caller's user_id. That
-- prevents cross-tenant data leaks (one user can't see another's
-- transactions) but doesn't distinguish what a logged-in user can
-- DO with their own account.
--
-- This migration adds a `role` column so the inviter can mint
-- read-only invites for spouses / advisors / accountants. The
-- backend's new `require_owner` middleware will 403 every
-- POST/PUT/PATCH/DELETE on the business endpoints when role !=
-- 'owner'. Read-only sessions can still log out, change their own
-- password, manage their own passkeys, etc. — see the routing
-- split in `main.rs`.
--
-- Existing rows backfill to 'owner' so this migration is safe to
-- run against a live single-household DB without locking anyone
-- out.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'owner';

-- Constrain to the known role values so a typo can't silently mint
-- a privilege that the middleware doesn't recognise.
ALTER TABLE users
    DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users
    ADD CONSTRAINT users_role_check CHECK (role IN ('owner', 'read_only'));

-- Mirror the column on invite_tokens so the inviter can pre-pick
-- the role at mint time; redemption copies it onto the new user.
-- Default 'owner' preserves the historical invite behaviour.
ALTER TABLE invite_tokens
    ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'owner';

ALTER TABLE invite_tokens
    DROP CONSTRAINT IF EXISTS invite_tokens_role_check;
ALTER TABLE invite_tokens
    ADD CONSTRAINT invite_tokens_role_check CHECK (role IN ('owner', 'read_only'));
