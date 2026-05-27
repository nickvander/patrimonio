-- Optional free-form note attached to a manual revaluation. Lives
-- on the snapshot row (one per revaluation) rather than the account
-- (overwritten on each revaluation) so the history is preserved —
-- "$500k → $550k because of the latest Zillow comp" stays attached
-- to the snapshot that set the $550k mark.
ALTER TABLE balance_snapshots
    ADD COLUMN IF NOT EXISTS valuation_notes TEXT;
