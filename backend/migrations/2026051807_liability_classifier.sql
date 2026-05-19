-- Server-side liability classifier.
--
-- Bug: the previous net-worth aggregations treated only
-- `account_type = 'credit'` as a liability. Loans, mortgages, student
-- loans, and the manual "Auto Loan" / "Mortgage" types all silently
-- contributed to `assets` instead of `liabilities`, which made the
-- server-side `net_worth` and `accounts_summary.net_worth` numbers
-- wrong whenever the user had any loan-shaped account.
--
-- The frontend's Dart categorizer (`categorizeAccount` in
-- account_category.dart) already does this correctly via substring
-- matching. This function mirrors that exact rule on the SQL side so
-- the two stay in lockstep:
--
--   credit (exact)        → credit cards
--   *loan*                 → student loan, auto loan, plain "loan", etc.
--   *mortgage*             → mortgage
--   *student*              → student loan (redundant with *loan* but
--                            explicit; matches the Dart rule)
--
-- IMMUTABLE + PARALLEL SAFE so it can be inlined in SELECT / WHERE
-- and used inside parallelised aggregates without forcing serial
-- execution.

CREATE OR REPLACE FUNCTION is_liability_account_type(t TEXT) RETURNS BOOLEAN
LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS $$
  -- Mirrors `categorizeAccount` in account_category.dart: substring
  -- matching (not exact match) so the dialog labels "Credit Card",
  -- "Auto Loan", "Student Loan" land in the liability bucket
  -- alongside Plaid's lowercase `credit` / `loan` / `mortgage` types.
  SELECT
       LOWER(COALESCE(t, '')) LIKE '%credit%'
    OR LOWER(COALESCE(t, '')) LIKE '%loan%'
    OR LOWER(COALESCE(t, '')) LIKE '%mortgage%'
    OR LOWER(COALESCE(t, '')) LIKE '%student%';
$$;
