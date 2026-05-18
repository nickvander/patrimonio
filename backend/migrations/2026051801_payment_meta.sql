-- Plaid `payment_meta` capture. For ACH transfers, wires, and bill-pay
-- rows the bank often sends a generic `name` ("Miscellaneous Debit",
-- "ACH PAYMENT") and a null `merchant_name` / `counterparty_name`. The
-- actual payee or payer string lives only in `payment_meta.payee` /
-- `payment_meta.payer` on the Plaid transaction. Without these columns
-- the display ladder runs out of fallbacks and the user sees the
-- generic label.
--
-- Both columns are nullable so existing rows keep rendering until the
-- next sync re-emits them. The display ladder in
-- `frontend/lib/utils/transaction_display.dart` now reads
-- counterparty → merchant → payment_payee → payment_payer →
-- original_description → description.
ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS payment_payee TEXT,
    ADD COLUMN IF NOT EXISTS payment_payer TEXT;
