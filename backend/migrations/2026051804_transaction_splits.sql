-- Split transactions.
--
-- A common PFM pattern: one $200 ATM withdrawal becomes "Cash · $100
-- groceries + $80 dinner + $20 tip." The original transaction (the
-- parent) stays on the books for audit but is replaced in every list
-- and aggregate by its children — otherwise the total spend would
-- double-count.
--
-- Design: `parent_id` is null for normal transactions, set to the
-- parent's id on every child. Every list query that wants user-facing
-- spend totals adds:
--
--     AND NOT EXISTS (SELECT 1 FROM transactions c WHERE c.parent_id = t.id)
--
-- which removes parents whose children exist. Children themselves are
-- regular rows — they show up in lists, contribute to budgets, count
-- as transactions for cash-flow and subscriptions.
--
-- Sign / amount invariants: every child must share the parent's sign
-- and currency; the sum of children must equal the parent's amount.
-- Both checks are enforced in the API layer (NOT a DB constraint —
-- writing them as triggers gets messy with floating-point amounts
-- and isn't worth the maintenance).
--
-- ON DELETE CASCADE so deleting a parent removes its children
-- automatically. Unsplitting is the inverse: delete all children, the
-- parent stays.

ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS parent_id UUID
        REFERENCES transactions(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_transactions_parent
    ON transactions (parent_id)
    WHERE parent_id IS NOT NULL;
