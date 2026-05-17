-- Hardware key support polish: remember whether each passkey is a
-- platform credential (Face ID / Touch ID / Windows Hello) or a
-- cross-platform / roaming one (USB / NFC security key). The
-- WebAuthn ceremony already accepts both — webauthn-rs's
-- start_passkey_registration leaves authenticatorAttachment
-- unrestricted by default — so this is purely so the Security screen
-- can render the right icon and label per row.
--
-- Values: 'platform' | 'cross-platform' | NULL when the browser
-- declined to report. We never branch on this server-side; it's a
-- display hint only.

ALTER TABLE passkey_credentials
ADD COLUMN authenticator_attachment TEXT;
