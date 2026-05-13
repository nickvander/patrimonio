# Phase 14: Market Data and Benchmarks

## Goal

Replace static benchmark assumptions with real market data and clear staleness/source indicators.

## Deliverables

- [ ] Select market data source for S&P 500, NASDAQ, BTC, and common holdings.
- [ ] Add backend market data service with caching.
- [ ] Store historical benchmark prices.
- [ ] Replace static chart benchmark math with fetched historical series.
- [ ] Add source and last-updated labels to benchmark UI.
- [ ] Add fallback behavior when market data is unavailable.
- [ ] Add cost controls/rate-limit handling.

## Success Criteria

- Net worth benchmark lines are based on real historical series.
- UI clearly shows when benchmark or quote data is stale.
- App still renders when external market data APIs fail.
- API usage remains within chosen free/low-cost tier.

## Test Plan

- Unit-test benchmark normalization against sample price series.
- API smoke with cache hit and cache miss.
- Browser check for source/staleness labels.
- Failure test with market provider unavailable.

## Open Questions

- Which provider balances cost, reliability, and allowed personal use?
- Should holdings prices come from Plaid where available or from the new market provider?
- How should crypto market data be reconciled between Coinbase/Bitso and benchmark sources?
