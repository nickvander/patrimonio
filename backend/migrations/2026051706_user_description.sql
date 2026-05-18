-- Per-row user description override (best-practice rename pattern).
--
-- Adds a nullable `user_description` to transactions, mirroring the
-- existing `user_category` and `user_notes` columns. The raw `description`
-- (Plaid `name`) stays immutable; the frontend's `displayLabel` helper
-- prefers `user_description` when present, otherwise falls through to
-- counterparty_name → merchant_name → original_description → description.
--
-- This is the override-not-mutation pattern — the original bank line
-- remains queryable and visible (the detail modal's "Raw bank text"
-- section still surfaces it), and clearing the override (setting to
-- NULL) reverts the row to the auto-picked label.
ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS user_description TEXT;
