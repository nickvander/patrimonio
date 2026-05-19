# Current state — snapshot

> **Last updated:** 2026-05-18 (evening — post-Top-3 sprint)
> **Branch:** feature branch with the latest sprint awaiting fast-forward merge to `main`.

## Where we are

Patrimonio is well past "MVP." All of NEXT.md's original Tier-1 items
have shipped. The app now does:

* Multi-user, invitation-based registration with TOTP / passkeys /
  recovery codes.
* Plaid Production for US accounts, including encrypted at-rest tokens,
  webhook receipt with ES256 verification, and per-item scoped sync.
* Mexico imports via CSV/PDF (Nu, Banamex, Cetesdirecto), and Coinbase
  + Bitso for crypto.
* FX-aware investment lots with dual-currency P&L.
* Encrypted nightly backups + a tested restore drill (see
  `docs/operations.md`); rotate-encryption-key one-shot binary shipped
  in the api image.
* Smarter transaction labels (counterparty → merchant → payment_meta
  → original_description → description, with a generic-prefix
  allowlist for "Miscellaneous Debit"-class strings), per-row rename
  + bulk-rename for clusters.
* "Since last login" banner with deep-link to the date-filtered tx
  list.
* Sticky reconnect banner that opens Plaid Link inline (no Management-
  tab detour).
* Recurring-charges card with merchant clustering + "Not a
  subscription" dismiss.
* Cross-currency cash-transfer linking (Wise / Remitly / Xoom /
  Western Union detection with implied FX rate). Auto-runs after
  every sync.
* Cash-flow chart bars are tappable — clicking a month group filters
  the Transactions tab to that date range.
* Split transactions with live-validated sum + Unsplit.
* CSRF defence-in-depth via `X-Requested-With` middleware.
* Trusted-proxy aware client_ip — XFF / X-Real-IP stripped from
  untrusted peers at the edge.
* `app_settings.user_id` (M7 leftover) — budgets / goals no longer
  leak across users.

## Evening sprint (2026-05-18, after the walkthrough)

Shipped in this session, in order:

* **`since_last_login` largest-move sign for liabilities.** The SQL
  now flips the delta for liability accounts via
  `is_liability_account_type`. A credit card going $500 → $1500 now
  reports as `-$1000` (net worth went down by $1000) instead of the
  previous false-positive `+$1000`.
* **Recovery-codes-low warning** on the Security screen. When the
  unused count drops below 3 the row swaps to an amber warning tile
  with a prominent "Regenerate" CTA. ≥ 3 still shows the original
  neutral card.
* **Cancelled-subscription detection.** Backend `dashboard.rs::
  detected_subscriptions` now tags each cluster `status:
  "active"|"cancelled"` and includes clusters whose most-recent
  charge is 91–548 days old (instead of dropping them). The
  frontend `SubscriptionsCard` renders cancelled rows in a
  collapsed "Stopped (N)" section below the active list, with a
  muted color treatment and no "× not a subscription" affordance.
* **Mexican parser polish.** New `parser::polish_description`
  helper strips trailing date suffixes (`20260418`, `18/04/2026`,
  `18-04-2026`) and a bilingual list of generic prefixes
  (`MISC DEBIT`, `ACH `, `POS `, `COMPRA `, `RETIRO `, `ABONO `,
  `CARGO `, `DEPOSITO `, `TRASPASO `, `PAGO `, …) when there's
  meaningful text after stripping. `detect_and_parse` runs every
  parser's output through it. Direct callers
  (`banamex::parse_csv`, etc.) still get the raw output so the
  existing unit tests aren't disturbed.
* **Production webhook activation.**
  * `GET /api/setup/status` now reports a "Plaid webhook URL"
    check so the Management tab can see at a glance whether push
    delivery is wired.
  * New `POST /api/institutions/update-webhook` iterates every
    Plaid item the caller owns and calls Plaid's
    `/item/webhook/update` with the configured URL — saves
    re-linking institutions that were created before
    `PLAID_WEBHOOK_URL` was set.
  * `docs/deployment.md` rewritten with a concrete single-VPS
    runbook: nginx + Let's Encrypt sample, `TRUSTED_PROXY_CIDRS`
    setup, webhook activation flow (re-link OR one-shot
    update-webhook), log rotation, backup pointers.

## Walkthrough verification (2026-05-18)

A full live walkthrough exercised every new path on real Production
data:

| Check | Result |
|---|---|
| Schema head | 2026051806 |
| API health | `{"status":"ok","database":"connected"}` |
| CSRF guard | POST without header → 403; with → 401 |
| XFF strip | spoofed XFF from untrusted peer → audit ip_address = NULL |
| Dashboard load | 14 API calls all 200 |
| Split dialog | renders + validates + API rejects bad payloads (422/404) |
| Subscriptions | "Interest earned" detected; dismiss snackbar + card hides |
| Chart drill-in | `May 1–May 31 ✕` chip + "Showing 37 of 50" filtered |
| Sync + auto-FX | 4 Plaid institutions synced clean; FX detector ran silently (0 candidates) |
| Frontend console | no errors |

## How to run locally

```bash
cd ~/patrimonio
docker compose up -d            # api, frontend, postgres, redis
docker compose ps               # all four Up / Healthy
```

* App:      `http://127.0.0.1:3000`
* API:      `http://127.0.0.1:8080`
* Postgres: host port `5433`
* Redis:    host port `6380`

### Backend changes

```bash
docker compose up -d --build api
docker logs -f patrimonio-api-1
```

### Frontend changes

```bash
docker compose up -d --build frontend
# Re-stamp security headers — the rebuild overwrites nginx config:
docker cp frontend/security_headers.conf \
  patrimonio-frontend-1:/etc/nginx/conf.d/security_headers.conf \
  && docker exec patrimonio-frontend-1 nginx -s reload
```

Worth scripting: see NEXT.md quick win for `scripts/dev-rebuild-frontend.sh`.

## Known caveats / "expected" behavior

| Behavior | Why |
|---|---|
| Flutter canvaskit can briefly hang on rapid clicks | Renderer quirk; recovers on next interaction. Not a code regression. |
| Auth audit `ip_address` is NULL in local dev | `TRUSTED_PROXY_CIDRS` empty by default → XFF stripped → no IP. Set the env var with nginx's IP in prod. |
| Plaid webhooks aren't actually being delivered yet | `PLAID_WEBHOOK_URL` must be a public HTTPS URL. Set it in `.env` once the deployment is reachable from Plaid's egress. `docs/deployment.md` now walks through nginx + Let's Encrypt + `POST /api/institutions/update-webhook` to backfill existing items. |
| Sandbox vs Production indistinguishable in the UI | No AppBar chip yet — see NEXT.md / FUTURE.md item "Sandbox vs Prod indicator". |
| "Interest earned" subscription is hidden once dismissed; no Unhide UI | Delete the `ignored_subscription_merchants` row directly to un-dismiss — UI affordance is a small follow-up. |
| Mexican CSV / PDF parsers used to produce raw bank strings | ✅ Fixed this session. `parser::polish_description` strips trailing date suffixes + a bilingual generic-prefix list before the rows hit the DB. |

## Pointers

* `work/OVERVIEW.md` — what the app is, institutions it tracks
* `work/NEXT.md` — top 3 + quick wins for the next session
* `work/FUTURE.md` — full backlog with per-item plans
* `work/DECISIONS.md` — architecture decision records
* `docs/operations.md` — backup / restore / key-rotation runbook
* `docs/multi-currency.md` — user-facing guide to USD/MXN model
