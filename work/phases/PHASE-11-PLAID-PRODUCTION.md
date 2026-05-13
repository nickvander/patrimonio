# Phase 11: Production Plaid Readiness

## Goal

Make real Plaid account linking and data population reliable enough for daily use.

## Scope

This phase covers Plaid setup, account linking, initial sync, reconnect flows, webhook handling, and user-visible sync status. It does not include tax calculation upgrades.

## Deliverables

- [ ] Confirm Plaid dashboard environment: sandbox, development, and production readiness.
- [ ] Document required Plaid products and webhook/redirect URLs for the deployed app.
- [ ] Add first-run UI that clearly labels sandbox/mock data versus real linked data.
- [ ] Persist Plaid provider error code/message metadata for linked institutions.
- [ ] Surface actionable states in the UI:
  - `setup_required`
  - `syncing`
  - `synced`
  - `pending`
  - `reconnect_required`
  - `error`
  - `manual`
- [ ] Add a reconnect flow for `ITEM_LOGIN_REQUIRED`, `USER_PERMISSION_REVOKED`, and related Plaid item errors.
- [ ] Add an initial sync progress view after successful Plaid Link.
- [ ] Add manual retry behavior for failed/reconnect-required institutions.
- [ ] Validate balances, transactions, and holdings with at least one real Plaid development institution.

## Success Criteria

- A user can click **Link Plaid**, authenticate, return to Patrimonio, and see accounts populate without needing developer intervention.
- If Plaid requires re-auth, the app explains the issue and offers a reconnect path.
- Setup failures are visible before account linking starts.
- Provider errors are logged and represented in API/UI state without leaking secrets.

## Test Plan

- `flutter analyze`
- API Docker build
- `NODE_PATH=/path/to/node_modules ./scripts/smoke.cjs`
- Browser check for Management setup panel and Plaid link button states
- Manual Plaid sandbox link test
- Manual Plaid development link test before production use

## Open Questions

- Which hosted domain will be used for Plaid redirect and webhook configuration?
- Which Plaid environment should be used first for real testing: development or production?
- Should this remain single-user, or should Plaid `client_user_id` become an authenticated user ID before production?
