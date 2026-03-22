# Phase 5: Polish & Deploy

**Goal:** Production-harden the app, add mobile targets, and create GCP deployment path.

## Deliverables
- [ ] iOS and Android Flutter targets
- [ ] Docker Compose production config (TLS, volumes, backups)
- [ ] GCP Cloud Run deployment (Dockerfile + cloudbuild.yaml)
- [ ] Database backup/restore scripts
- [ ] Performance optimization (materialized views, query tuning)
- [ ] Error handling and retry logic for all sync operations
- [ ] Optional: passphrase lock for self-hosted access

## Success Criteria
- App runs on mobile devices
- `gcloud run deploy` works from CI
- Database can be backed up and restored
- All sync operations handle errors gracefully
