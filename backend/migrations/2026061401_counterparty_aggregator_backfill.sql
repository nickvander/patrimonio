-- Backfill: repair transactions whose stored `counterparty_name` is a payment
-- AGGREGATOR (Square, Stripe, PayPal, Toast, etc.) rather than the merchant the
-- user actually recognises. This is the history-repair half of the
-- `best_counterparty()` scoring fix in `services/sync.rs`: the scorer now
-- demotes payment_app / financial_institution / income_source types below any
-- real MERCHANT, so "SQ *COFFEESHOP" surfaces as the coffee shop instead of
-- "Square".
--
-- The cursor-based Plaid /transactions/sync only re-emits *changed* rows, so
-- already-synced history would keep the wrong name until something edits it.
-- For Plaid-enriched rows the real merchant survives in `merchant_name`
-- (the detail view already shows it as a subtitle), so we promote it into
-- `counterparty_name` — the field the list row and detail title read first.
--
-- Conservative by design: only an EXACT (case-insensitive) aggregator name is
-- replaced, and only when a distinct non-empty `merchant_name` exists to
-- promote. Idempotent — re-running changes nothing once the names match.
UPDATE transactions
SET counterparty_name = merchant_name
WHERE merchant_name IS NOT NULL
  AND btrim(merchant_name) <> ''
  AND counterparty_name IS NOT NULL
  AND lower(btrim(counterparty_name)) <> lower(btrim(merchant_name))
  AND lower(btrim(counterparty_name)) IN (
    'square', 'square inc', 'block', 'block inc',
    'stripe', 'stripe inc',
    'paypal', 'paypal inc',
    'toast', 'toast inc',
    'sumup', 'clip', 'clip mx',
    'mercado pago', 'mercadopago',
    'venmo', 'cash app', 'cashapp',
    'adyen', 'shopify', 'shopify inc',
    'zettle', 'izettle'
  );
