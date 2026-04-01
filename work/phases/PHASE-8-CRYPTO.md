# Phase 8: Insights & Crypto Integration

## Goal
Modernize the dashboard by decoupling analytical insights and establishing a robust, automated cryptocurrency tracking system.

## Deliverables
- [x] **Database Schema Migration**: Added `ticker_symbol`, `crypto_amount`, and `coinbase_account_id` to the `accounts` table.
- [x] **Coinbase OAuth 2.0**: Implemented full OAuth 2.0 flow (redirect, callback, token exchange, and refresh).
- [x] **Crypto Valuation Service**: Real-time spot price fetching from Coinbase (USD) and Bitso (MXN).
- [x] **Unified Sync Engine**: Refactored sync engine to handle OAuth-based crypto institutional syncing.
- [x] **UI Modernization**:
    - [x] Integrated "Crypto" category in Accounts List.
    - [x] Real-time "Estimated Value" display for digital assets.
    - [x] Simplified "Management" tab with high-visibility "Link" buttons.
    - [x] Automated Status feedback for OAuth redirects.

## Technical Details
- **Encryption**: All OAuth tokens are encrypted using AES-256-GCM before storage.
- **Valuation**: Prices are fetched on-demand during sync to ensure the dashboard's net worth calculation is always up-to-date.
- **Error Handling**: Custom redirect logic to handle missing Environment Variables and connection failures.
