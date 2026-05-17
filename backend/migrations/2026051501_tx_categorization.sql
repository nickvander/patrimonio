-- Richer Plaid categorization fields. We were previously only storing
-- personal_finance_category.primary which produces vague labels like
-- "LOAN_PAYMENTS" or "TRANSFER_OUT". Plaid also returns a `.detailed`
-- enum (e.g. "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT") and a payment_channel
-- ("online" / "in_store" / "other") that make the UI much more
-- informative. Both are added as nullable so existing rows keep
-- working until they're re-synced.
ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS category_detailed TEXT,
    ADD COLUMN IF NOT EXISTS payment_channel TEXT;
