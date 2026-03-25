-- Delete duplicate transactions before adding unique constraint
DELETE FROM transactions T1
USING transactions T2
WHERE T1.id > T2.id
  AND T1.account_id = T2.account_id
  AND T1.external_id = T2.external_id;

-- Add unique constraint for duplicate detection in transactions
-- Note: external_id must not be null for this to be effective as a signature
ALTER TABLE transactions ADD CONSTRAINT unique_account_transaction UNIQUE (account_id, external_id);
