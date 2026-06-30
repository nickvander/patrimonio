-- Track where each FX row came from so a user-entered override can outrank the
-- automated open.er-api.com fetch. Existing rows were all API-sourced, so we
-- default to 'api'; manual overrides insert source='manual'.
--
-- latest_usd_mxn_rate (api/dashboard.rs) now prefers the freshest 'manual' row
-- over an 'api' row, letting users correct a bad/missing upstream rate that
-- would otherwise collapse to the FX_FALLBACK_USD_MXN=20.0 sentinel.
ALTER TABLE exchange_rates ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'api';
