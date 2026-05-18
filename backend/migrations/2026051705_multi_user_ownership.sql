-- Multi-user ownership columns (audit follow-up M7).
--
-- Previously the financial-data tables (institutions, accounts,
-- transactions, holdings, balance_snapshots) had no `user_id` column.
-- That was safe only while the system enforced exactly one bootstrap
-- user — adding a second `users` row would have given the second user
-- read access to every other user's financial data, because no query
-- carried an ownership predicate.
--
-- This migration makes the schema multi-user-safe so registration
-- (and eventually invite flows) can be opened up without leaking
-- data across tenants. The corresponding query-side changes land in
-- the same commit as this migration; the schema change alone is not
-- enough.
--
-- Backfill strategy:
--   1. Add nullable user_id columns.
--   2. Backfill institutions from the sole bootstrap user (or skip
--      if the table is empty).
--   3. Cascade down via JOINs: accounts ← institutions, transactions
--      ← accounts, holdings ← accounts, balance_snapshots ← accounts.
--   4. SET NOT NULL on every column.
--   5. Add `(user_id, …)` covering indexes so the per-user filter
--      doesn't tablescan once the row count grows.

-- Step 1: nullable columns ---------------------------------------------------

ALTER TABLE institutions
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE holdings
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE balance_snapshots
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;

-- Step 2: backfill institutions to the bootstrap user. We pick the
-- earliest-created user as canonical; in a single-user world that's
-- the only row. If the users table is empty (fresh install with no
-- bootstrap yet), there are no institutions to backfill either.
UPDATE institutions
SET user_id = (SELECT id FROM users ORDER BY created_at ASC LIMIT 1)
WHERE user_id IS NULL
  AND EXISTS (SELECT 1 FROM users);

-- Step 3: cascade ownership down.
UPDATE accounts a
SET user_id = i.user_id
FROM institutions i
WHERE a.institution_id = i.id
  AND a.user_id IS NULL;

UPDATE transactions t
SET user_id = a.user_id
FROM accounts a
WHERE t.account_id = a.id
  AND t.user_id IS NULL;

UPDATE holdings h
SET user_id = a.user_id
FROM accounts a
WHERE h.account_id = a.id
  AND h.user_id IS NULL;

UPDATE balance_snapshots b
SET user_id = a.user_id
FROM accounts a
WHERE b.account_id = a.id
  AND b.user_id IS NULL;

-- Step 4: enforce NOT NULL only when the table is non-empty AND a
-- bootstrap user exists. Fresh installs (no users, no data) leave
-- the columns nullable until first bootstrap; the application sets
-- user_id explicitly on every INSERT going forward, so production
-- rows will never have NULL even before this constraint binds.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM users) THEN
        -- Only ALTER if we successfully backfilled (no nulls remain).
        IF NOT EXISTS (SELECT 1 FROM institutions WHERE user_id IS NULL) THEN
            ALTER TABLE institutions ALTER COLUMN user_id SET NOT NULL;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM accounts WHERE user_id IS NULL) THEN
            ALTER TABLE accounts ALTER COLUMN user_id SET NOT NULL;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM transactions WHERE user_id IS NULL) THEN
            ALTER TABLE transactions ALTER COLUMN user_id SET NOT NULL;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM holdings WHERE user_id IS NULL) THEN
            ALTER TABLE holdings ALTER COLUMN user_id SET NOT NULL;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM balance_snapshots WHERE user_id IS NULL) THEN
            ALTER TABLE balance_snapshots ALTER COLUMN user_id SET NOT NULL;
        END IF;
    END IF;
END $$;

-- Step 5: per-user covering indexes. For each table the leading
-- column is user_id, followed by the column we most commonly filter
-- or sort by next so the index can satisfy both predicates in one
-- seek. Existing indexes are left in place — Postgres will pick the
-- best one per query, and the per-user variants are pure addition.
CREATE INDEX IF NOT EXISTS idx_institutions_user ON institutions (user_id, id);
CREATE INDEX IF NOT EXISTS idx_accounts_user ON accounts (user_id, id);
CREATE INDEX IF NOT EXISTS idx_transactions_user_date ON transactions (user_id, date DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_holdings_user ON holdings (user_id, account_id);
CREATE INDEX IF NOT EXISTS idx_balance_snapshots_user_date ON balance_snapshots (user_id, as_of_date DESC);
