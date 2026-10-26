-- Personal Access Tokens (PATs) for headless API, CLI, and MCP access.
--
-- Like `user_sessions`, only the 32-byte SHA-256 digest (`token_hash`) is
-- stored at rest; the raw `pat_<base64url>` secret is returned once at
-- creation time. `token_prefix` stores the non-sensitive leading characters
-- (e.g. `pat_8xK9mN2p`) so the user can identify and revoke individual tokens
-- on the Security screen.
--
-- `scope` defaults to `read_only`, which forces `AuthContext.role = 'read_only'`
-- even when the owning user is `'owner'` — so `require_owner` automatically
-- rejects mutating business endpoints (POST/PUT/PATCH/DELETE) with 403.

CREATE TABLE IF NOT EXISTS user_api_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    token_prefix TEXT NOT NULL,
    token_hash BYTEA NOT NULL UNIQUE,
    scope TEXT NOT NULL DEFAULT 'read_only'
        CHECK (scope IN ('read_only', 'read_write')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_user_api_tokens_user_active
    ON user_api_tokens (user_id, created_at DESC)
    WHERE revoked_at IS NULL;
