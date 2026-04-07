# Phase 10: V1 Stability & Polish

## Goal
Audit and resolve UI/UX inconsistencies, standardize visual components, and ensure the application is production-ready for V1.

## Deliverables
- [x] **Smart Category Icons**: Colorful, context-aware icons for transaction categories (food, travel, payments, recreation, etc.)
- [x] **Title-Cased Descriptions**: Raw ALL-CAPS bank text normalized to readable Title Case.
- [x] **Transaction Search**: Real-time search/filter bar on the Transactions tab.
- [x] **PDF Export (Tax)**: One-page tax summary PDF download alongside existing CSV export.
- [x] **Portfolio Legend Fix**: Labels now show holding name ("Investment") instead of raw security type ("SEC").
- [x] **Cash Flow Chart Polish**: Wider bars (22px), clear Income vs Spending separation.
- [x] **Deprecated API Cleanup**: Removed legacy `plaid_sync` endpoint references.
- [x] **Filing Status Enhancements**: Head of Household bracket support in tax engine.

## Remaining Known Issues (Post-V1)
| Issue | Tab | Severity |
|-------|-----|----------|
| Portfolio legend shows "Investment" 4× (sandbox limitation — all holdings have `name: "Investment"`) | Portfolio | Low (data-driven) |
| Return shows "+1234467.00%" (wrong sandbox math) | Portfolio | Medium |
| "ACH Electronic CreditGUSTO PAY 123456" mixed-case not fully normalized | Transactions | Low |
| Credit Card icons are uniform gray `payment` style — could use variation | Transactions | Low |
| Tax Planning shows $0.00 everywhere (no taxable events in sandbox data) | Tax Planning | Expected |

## Technical Details
- **Icon Mapping**: `_getCategoryIcon()` in `transactions_tab.dart` maps Plaid categories to Material icons with per-category color theming.
- **Title Case**: Dart `_toTitleCase()` normalizes whitespace and capitalizes each word, preserving short words.
- **PDF Generation**: Backend uses `printpdf` crate; served via `GET /api/tax/report/pdf?year=&status=`.
