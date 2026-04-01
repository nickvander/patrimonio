# Phase 9: Tax Planning & Reports

## Goal
Establish a comprehensive tax planning and reporting center to estimate tax liabilities for US and Mexico-based users.

## Deliverables
- [ ] **Tax Estimation Engine (Backend)**:
    - [ ] `TaxService`: Logic to categorize transactions into "Ordinary Income" and "Capital Gains".
    - [ ] **US Estimates**: Progressive 10%–37% bracket calculator based on 2026 IRS schedules.
    - [ ] **MX Estimates**: ISR Table calculator for "Persona Física" (2025/2026).
- [ ] **Capital Gains Tracker**:
    - [ ] Calculate realized gains/losses for all "Sell" transactions.
    - [ ] Simple "Average Cost" or "FIFO" tracking for Crypto and Stocks.
- [ ] **Data Export & Reporting**:
    - [ ] **CSV Export**: Annual transaction history download.
    - [ ] **PDF Summary**: One-page tax summary for annual filing preparation.
- [ ] **Tax Dashboard (Frontend)**:
    - [ ] New "Tax Planning" Tab in the Dashboard.
    - [ ] Interactive status toggle (Single, Married, Head of Household).
    - [ ] Real-time "Effective Tax Rate" and "Estimated Liability" visualization.

## Technical Details
- **Revenue Logic**: Leverage existing `transactions` table using specific `category` and `type` filters.
- **Bracket Accuracy**: Hardcode current thresholds with a "Last Updated: 2026" disclaimer in the UI.
- **Exports**: Use a Rust library (like `csv`) for data generation and standard browsers headers for downloads.
