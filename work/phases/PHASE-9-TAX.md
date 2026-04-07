# Phase 9: Tax Planning & Reports

## Goal
Establish a comprehensive tax planning and reporting center to estimate tax liabilities for US and Mexico-based users.

## Deliverables
- [x] **Tax Estimation Engine (Backend)**:
    - [x] `TaxService`: Logic to categorize transactions into "Ordinary Income" and "Capital Gains".
    - [x] **US Estimates**: Progressive 10%–37% bracket calculator based on 2026 IRS schedules.
    - [x] **MX Estimates**: ISR Table calculator for "Persona Física" (2025/2026).
- [x] **Capital Gains Tracker**:
    - [x] Calculate realized gains/losses for all "Sell" transactions.
    - [x] Simple "Average Cost" or "FIFO" tracking for Crypto and Stocks.
- [x] **Data Export & Reporting**:
    - [x] **CSV Export**: Annual transaction history download.
    - [x] **PDF Summary**: One-page tax summary for annual filing preparation.
- [x] **Tax Dashboard (Frontend)**:
    - [x] New "Tax Planning" Tab in the Dashboard.
    - [x] Interactive status toggle (Single, Married, Head of Household).
    - [x] Real-time "Effective Tax Rate" and "Estimated Liability" visualization.

## Technical Details
- **Revenue Logic**: Leverage existing `transactions` table using specific `category` and `type` filters.
- **Bracket Accuracy**: Hardcode current thresholds with a "Last Updated: 2026" disclaimer in the UI.
- **Exports**: Use a Rust library (like `csv`) for data generation and standard browsers headers for downloads.
