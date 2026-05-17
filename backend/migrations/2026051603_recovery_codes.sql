-- One-time recovery codes for self-service password reset. Shown
-- exactly once at bootstrap (and on regeneration); only the SHA-256
-- of each code is stored. The user redeems a code via /api/auth/recover
-- by supplying { username, code, new_password }.

CREATE TABLE recovery_codes (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash BYTEA NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    used_at TIMESTAMPTZ,
    used_ip TEXT
);

-- Fast lookup of unused codes belonging to a user.
CREATE INDEX idx_recovery_codes_user_unused
    ON recovery_codes (user_id)
    WHERE used_at IS NULL;
