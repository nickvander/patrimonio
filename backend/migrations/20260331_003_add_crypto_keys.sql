-- Add columns for crypto API integrations
ALTER TABLE institutions ADD COLUMN api_key_enc BYTEA;
ALTER TABLE institutions ADD COLUMN api_secret_enc BYTEA;
ALTER TABLE institutions ADD COLUMN api_pass_enc BYTEA;
