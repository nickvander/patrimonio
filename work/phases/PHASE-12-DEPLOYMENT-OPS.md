# Phase 12: Deployment, Backups, and Operations

## Goal

Move Patrimonio from a local launch stack to a production-ready hosted setup with secret management, backups, and basic operational visibility.

## Deliverables

- [ ] Select hosting target for frontend and API.
- [ ] Configure managed PostgreSQL and Redis.
- [ ] Move Plaid, Coinbase, Bitso, FX, and encryption settings into a secret manager.
- [ ] Create production environment documentation.
- [ ] Add backup and restore scripts/runbooks for PostgreSQL.
- [ ] Add uptime checks for frontend and `/api/health`.
- [ ] Add structured API error logging.
- [ ] Add deployment smoke check that runs after release.
- [ ] Configure CORS and Plaid redirect/webhook URLs for the hosted domain.

## Success Criteria

- Fresh deployment can be created from documented steps.
- App survives container restarts without data loss.
- Database can be restored from a backup in a test environment.
- Secrets are not stored in repo files or shell history.
- A failed deploy or down API is visible quickly.

## Test Plan

- Deploy to staging.
- Run API health and browser smoke against staging.
- Run backup and restore into a disposable database.
- Rotate one non-critical secret and confirm the app reloads it through the platform.

## Open Questions

- Preferred hosting target: GCP Cloud Run/Firebase, a VPS, or another platform?
- Is remote access single-user behind private auth, or should the app add an auth layer before hosting publicly?
- What backup retention period is appropriate for personal financial data?
