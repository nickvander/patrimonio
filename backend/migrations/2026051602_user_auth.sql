-- User authentication: single-user-today, multi-user-ready schema.
-- Adds users, opaque server-side sessions, and an auth audit trail.

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL,
    email TEXT,
    password_hash TEXT NOT NULL,
    -- Reserved for follow-up TOTP enablement; null until enrolled.
    totp_secret_enc BYTEA,
    totp_enabled BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at TIMESTAMPTZ
);

-- Case-insensitive uniqueness so "Nick" and "nick" cannot both exist.
CREATE UNIQUE INDEX idx_users_username_lower ON users (LOWER(username));
CREATE UNIQUE INDEX idx_users_email_lower ON users (LOWER(email)) WHERE email IS NOT NULL;

-- Server-side sessions. The cookie carries the raw token; the DB stores
-- only its SHA-256 hash so a DB leak does not yield live session tokens.
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash BYTEA NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    user_agent TEXT,
    ip_address TEXT
);

CREATE INDEX idx_user_sessions_user ON user_sessions (user_id);
CREATE INDEX idx_user_sessions_expiry ON user_sessions (expires_at) WHERE revoked_at IS NULL;

-- Append-only auth event log. Used for rate-limiting decisions and
-- post-incident review.
CREATE TABLE auth_audit (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event TEXT NOT NULL,
    username_attempt TEXT,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    ip_address TEXT,
    user_agent TEXT,
    success BOOLEAN NOT NULL,
    detail TEXT
);

CREATE INDEX idx_auth_audit_recent ON auth_audit (occurred_at DESC);
CREATE INDEX idx_auth_audit_username_recent
    ON auth_audit (LOWER(username_attempt), occurred_at DESC)
    WHERE username_attempt IS NOT NULL;
CREATE INDEX idx_auth_audit_ip_recent
    ON auth_audit (ip_address, occurred_at DESC)
    WHERE ip_address IS NOT NULL;
