-- Add support for tracking detailed sync errors
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS last_sync_error TEXT;
