# Phase 2: Plaid Integration

**Goal:** Connect US financial institutions via Plaid, sync accounts, balances, transactions, and investment holdings.

## Deliverables
- [ ] Plaid developer account setup
- [ ] Plaid Link integration in Flutter (WebView)
- [ ] Account connection flow (link → store token → sync)
- [ ] Transaction sync engine (`/transactions/sync`)
- [ ] Investment holdings sync (`/investments/holdings/get`)
- [ ] Balance snapshot scheduler (daily cron)
- [ ] Webhook receiver for real-time updates
- [ ] Encrypted token storage (AES-256-GCM)

## Institutions to Test
1. SoFi Bank (banking)
2. Chase (credit card)
3. Fidelity (brokerage + NetBenefits)
4. Robinhood (brokerage)

## Success Criteria
- Link at least one institution via Plaid Link in browser
- Account balances appear in database after sync
- Transactions are stored with category, merchant, amount
- Investment holdings show stock-level detail
- Balance snapshots created daily
