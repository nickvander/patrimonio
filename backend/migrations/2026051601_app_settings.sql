-- Single-user key/value store for app-level preferences that don't fit
-- a dedicated table (yet). Budgets and net-worth goals were previously
-- localStorage-only; persisting them server-side means they survive a
-- browser data wipe and become source-of-truth for future multi-device
-- access. The `value` column is JSONB so per-key shape can evolve.

CREATE TABLE IF NOT EXISTS app_settings (
    key         TEXT PRIMARY KEY,
    value       JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
