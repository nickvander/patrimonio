-- Daily closing levels for market benchmarks (e.g. the S&P 500), used to plot
-- the user's net worth against "the market". Populated lazily from a free,
-- keyless source (Yahoo Finance chart API) and cached here so we don't hit the
-- network on every dashboard read — exactly the pattern exchange_rates uses
-- for FX.
--
-- `symbol` is our internal id ('SP500'); `price_date` is the trading day;
-- `close` is the index close. One row per (symbol, day); re-fetches upsert.
CREATE TABLE IF NOT EXISTS benchmark_prices (
    id BIGSERIAL PRIMARY KEY,
    symbol TEXT NOT NULL,
    price_date DATE NOT NULL,
    close NUMERIC(18, 4) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (symbol, price_date)
);

CREATE INDEX IF NOT EXISTS idx_benchmark_symbol_date
    ON benchmark_prices (symbol, price_date DESC);
