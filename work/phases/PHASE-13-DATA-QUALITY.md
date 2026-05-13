# Phase 13: Data Quality and Reconciliation

## Goal

Make imported and synced financial data auditable, explainable, and correct enough to trust.

## Deliverables

- [ ] Add source metadata to account, transaction, holding, and balance views.
- [ ] Add duplicate detection for CSV/PDF imports beyond provider IDs.
- [ ] Add reconciliation checks between provider balances and local snapshots.
- [ ] Add category review/correction workflow.
- [ ] Add transaction notes or manual overrides.
- [ ] Add stale data indicators for institutions and exchange rates.
- [ ] Add import preview summaries: new, duplicate, changed, skipped.
- [ ] Add basic data audit screen for sync/import history.

## Success Criteria

- Re-importing the same file does not silently duplicate transactions.
- Account balance discrepancies are visible and traceable to source data.
- Users can correct categories without losing provider/source context.
- Dashboard values can be explained from underlying accounts and transactions.

## Test Plan

- Re-import the same Nu/Banamex/Cetes sample twice.
- Import a modified sample and verify changed/new/skipped counts.
- Simulate stale sync and confirm the UI marks it clearly.
- Run browser smoke after category/source UI changes.

## Open Questions

- Should manual category changes overwrite provider categories or live as user overrides?
- How much source metadata should be visible by default versus behind detail views?
- Should reconciliation be daily, on-demand, or both?
