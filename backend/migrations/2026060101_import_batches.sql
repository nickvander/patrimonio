-- Tag imported transactions with the import batch they arrived in + the
-- source file, so an import can be listed and undone as a unit. Both are
-- nullable: pre-existing rows and non-import transactions have neither.
-- (Past imports therefore have no batch_id — those are cleaned up via the
-- account + date-range bulk delete instead.)
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS import_batch_id UUID;
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS import_file TEXT;

CREATE INDEX IF NOT EXISTS idx_transactions_import_batch
    ON transactions (import_batch_id)
    WHERE import_batch_id IS NOT NULL;
