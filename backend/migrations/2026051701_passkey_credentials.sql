-- Passkeys (FIDO2 / WebAuthn) — phishing-resistant credentials that
-- live on the user's device (phone biometric, hardware key, OS
-- keychain). Additive to the password + TOTP flow; never replaces it.
--
-- Schema notes
--   credential_id: raw bytes the authenticator returned at registration
--     time. Indexed because the login-finish step looks the credential
--     up by this value.
--   passkey_json: the full webauthn-rs `Passkey` struct serialized as
--     JSON. We round-trip the whole blob rather than modelling every
--     subfield (AAGUID, COSE pubkey, sign counter, backup flags,
--     transports, …) because the crate may add fields between minor
--     versions and we don't want to chase a migration each time.
--   nickname: optional user-supplied label so they can tell their
--     iPhone apart from their Yubikey in the Security UI.
--   sign_count is maintained inside passkey_json by the library and
--     bumped on every successful authentication.

CREATE TABLE passkey_credentials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id BYTEA NOT NULL UNIQUE,
    passkey_json JSONB NOT NULL,
    nickname TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ
);

CREATE INDEX idx_passkey_credentials_user ON passkey_credentials (user_id);
