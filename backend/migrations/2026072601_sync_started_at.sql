-- When the current sync run was stamped onto an institution.
--
-- `sync_status = 'syncing'` had no timestamp, so a run that never reached a
-- terminal state left the row stuck in 'syncing' with nothing to age it off:
-- the Settings card spun forever and the only escape was a manual re-sync.
-- Two ways that happens — the process restarting mid-sync (the reported
-- case), and a run wedging on a hung upstream call.
--
-- The restart case is reapable without this column (anything still 'syncing'
-- at boot is stale by definition, since a run cannot survive the process).
-- The wedged-run case needs a start time to measure against, which is what
-- this adds.
--
-- Nullable and additive: existing rows keep NULL, and the reaper treats a
-- NULL start on a 'syncing' row as "stamped by an older binary" — still
-- reapable at boot, just not by the age-based watchdog.
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS sync_started_at TIMESTAMPTZ;

-- Partial index: the reaper's only query is "rows currently syncing", which
-- is near-empty in steady state.
CREATE INDEX IF NOT EXISTS idx_institutions_syncing
    ON institutions (sync_started_at)
    WHERE sync_status = 'syncing';
