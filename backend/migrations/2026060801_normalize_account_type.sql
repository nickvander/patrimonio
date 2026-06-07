-- Normalise account_type casing so manually-created / statement-imported
-- accounts ("Checking", "Credit Card", "CD") share the lowercase convention of
-- Plaid-synced ones ("checking", "credit card"). Without this they split into
-- separate rows in the dashboard's GROUP BY account_type breakdown (an
-- imported "Checking" sitting apart from a synced "checking").
--
-- Asset/liability classification already lowercases before matching, so this
-- is display/grouping hygiene only — no balances change. New inserts are
-- lowercased in the create_account handler.
UPDATE accounts
   SET account_type = lower(account_type)
 WHERE account_type IS NOT NULL
   AND account_type <> lower(account_type);
