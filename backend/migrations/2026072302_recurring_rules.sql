-- Recurring & scheduled transactions (MVP): user-defined rules that
-- describe an expected repeating cash flow (rent, salary, subscriptions
-- the detector can't see because they're manual/cash).
--
-- Deliberately NO auto-posting in this MVP — rules only power an
-- "expected upcoming" view on the cash-flow tab. Nothing here writes to
-- `transactions`, so a rule can never corrupt real balances.
--
-- Sign convention matches `transactions.amount`: negative = outflow
-- (expense), positive = inflow (income).
--
-- `anchor_day` is the day-of-month anchor for monthly/yearly cadences
-- (1-31, clamped to the target month's length at expansion time so an
-- anchor of 31 lands on Feb 28/29). Weekly/biweekly cadences ignore it
-- and step in exact 7/14-day increments from `next_due_date`.
CREATE TABLE IF NOT EXISTS recurring_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    category TEXT,
    -- Same precision as transactions.amount so an expected row can mirror
    -- any real transaction exactly.
    amount DECIMAL(15,2) NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    cadence TEXT NOT NULL CHECK (cadence IN ('weekly', 'biweekly', 'monthly', 'yearly')),
    anchor_day SMALLINT NOT NULL CHECK (anchor_day BETWEEN 1 AND 31),
    -- The seed date occurrences are expanded from. Read paths compute the
    -- effective "next occurrence on/after today" from this + cadence, so
    -- no cron job is needed to keep it fresh.
    next_due_date DATE NOT NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The management list and the upcoming expansion both read "my rules,
-- active first" — index the access path.
CREATE INDEX IF NOT EXISTS idx_recurring_rules_user_active
    ON recurring_rules(user_id, active);
