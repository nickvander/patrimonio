-- Clean up duplicate holdings created by the pre-idempotent Plaid sync.

WITH ranked AS (
    SELECT
        id,
        ROW_NUMBER() OVER (
            PARTITION BY account_id, symbol, name, quantity, price, value
            ORDER BY updated_at DESC, id DESC
        ) AS rn
    FROM holdings
    WHERE external_id IS NULL
)
DELETE FROM holdings h
USING ranked r
WHERE h.id = r.id
  AND r.rn > 1;

-- Legacy rows used price as cost_basis, which produced unusable gain percentages.
UPDATE holdings
SET cost_basis = value
WHERE external_id IS NULL
  AND symbol = 'SEC'
  AND name = 'Investment'
  AND value IS NOT NULL
  AND cost_basis IS NOT NULL
  AND cost_basis <= price;
