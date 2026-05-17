-- Plaid transaction enrichment columns. The previous schema stored only
-- `description` (Plaid `name`) and `merchant_name`, which leaves a lot of
-- Plaid Production payload on the table:
--
--   * `original_description` is the raw bank line. It survives when Plaid's
--     `name` falls back to a generic "Miscellaneous Credit" / "Robinhood"
--     label because the bank itself sent something terser.
--   * `counterparties[]` is Plaid's enriched merchant-entity array. Each
--     entry has a name + logo URL + confidence level — for many transactions
--     where `merchant_name` is null, the right merchant lives here under a
--     HIGH or VERY_HIGH confidence_level entry.
--
-- All three columns are nullable so existing rows keep rendering until they
-- are re-synced. The UI picks the best label across
-- counterparty_name → merchant_name → original_description → description.
ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS original_description TEXT,
    ADD COLUMN IF NOT EXISTS counterparty_name TEXT,
    ADD COLUMN IF NOT EXISTS counterparty_logo_url TEXT;
