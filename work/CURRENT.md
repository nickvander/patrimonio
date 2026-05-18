# Current state — snapshot

> **Last updated:** 2026-05-18
> **Branch:** `main` (origin/main caught up — nothing local-only)

## Where we are

Patrimonio is well past the "demo" phase. Plaid Production is live with
real bank credentials; the auth stack has passwords, TOTP, recovery
codes, passkeys (FIDO2), and invitation-based registration; the
backend is multi-user-safe end-to-end (M7); investment cost basis is
FX-aware with per-lot historical USDMXN tracking. Day-to-day use is
the loop the user actually has.

This session (2026-05-17 → 18) shipped a substantial batch:

- **Security audit follow-ups**: Plaid webhook ES256 JWT verification
  (audit H3); multi-user `user_id` columns + ownership predicates on
  every financial-data query (audit M7).
- **Invitation registration**: `invite_tokens` table + mint/list/revoke
  endpoints + public `/api/auth/register` redemption + the
  `RegisterScreen` UI that opens when the URL contains `?invite=...`.
- **Transaction polish**: per-row `user_description` override (the
  rename pattern), pencil icon in the detail modal, displayLabel
  picks user override first. Plaid counterparties + original
  description were already shipped earlier.
- **FX-aware cost basis**: `holding_lots` table + sync engine pull
  from `/investments/transactions/get` writing per-buy lots with
  historical USDMXN, FIFO depletion on sell with zero-qty marker
  rows for idempotency. `/api/dashboard/holdings` returns dual-
  currency P&L using lots when present + current-FX fallback.
- **Dual-currency portfolio panel**: USD + MXN tiles side-by-side
  with explicit "US Dollar" / "Mexican Peso" subtitles (no naked
  acronyms).
- **Theme/contrast pass**: light-mode text alphas bumped (0.7→0.85
  for muted, 0.7→0.78 for subtle, 0.56→0.65 for faint); ~20
  hardcoded dark-only neon hex literals migrated to brightness-
  aware palette tokens (`context.positive`, `context.tealAccent`,
  etc.). AppBar `iconTheme` + `actionsIconTheme` set explicitly so
  the Security shield + Sign-out arrow stay visible in both modes.
- **KPI tile redesign**: Net worth gets a hero treatment (accent
  wash background + left-edge bar). The other four (Assets,
  Liabilities, Cash, Investments) share a coherent neutral
  surface with a 6×6 accent dot before each label — no more
  colored outlines around `$0.00 Liabilities`.
- **Docs**: `docs/multi-currency.md` explains the two pipelines in
  plain English (investment lots = shipped, cross-currency cash
  transfers = future item 2b).

## How to run locally

```bash
cd ~/patrimonio
docker compose up -d            # starts api, frontend, postgres, redis
docker compose ps               # all four should be Up / Healthy
```

- App:      `http://127.0.0.1:3000`
- API:      `http://127.0.0.1:8080`
- Postgres: host port `5433` (inside: 5432)
- Redis:    host port `6380` (inside: 6379)

### Backend changes

```bash
docker compose up -d --build api      # rebuild + restart
docker logs -f patrimonio-api-1       # tail
```

### Frontend changes

```bash
docker compose up -d --build frontend
# After recreate, re-stamp the security headers (they live in the
# nginx config, which the build overwrites):
docker cp frontend/security_headers.conf \
  patrimonio-frontend-1:/etc/nginx/conf.d/security_headers.conf \
  && docker exec patrimonio-frontend-1 nginx -s reload
```

(The CSP rebuild gotcha: build → live container has the bundled
JS but its nginx config doesn't include the most-recent security
headers tweak; re-copying the file + reloading nginx fixes it.
Worth automating eventually — see `work/NEXT.md`.)

## Known caveats / "expected" behavior

| Behavior | Why |
|---|---|
| AppBar action icons cached after a frontend rebuild | Hard-reload (Cmd/Ctrl+Shift+R) bypasses the browser bundle cache. SW is the self-unregistering kind so it isn't the cause. |
| MXN P&L tile equals current-FX conversion of USD | `holding_lots` hasn't populated yet — click Sync. |
| `INVALID_PRODUCT` / `PRODUCTS_NOT_SUPPORTED` in api logs after a sync | An institution doesn't expose Plaid's `investments` product. Cash + balance sync still works for it. |
| "Miscellaneous Credit" / "Miscellaneous Debit" rows | Plaid `name` is genuinely "Miscellaneous Debit" for some transactions — the bank didn't send better. Use the pencil-icon rename in the detail modal. |
| Cross-currency cash transfers (Wise → Nu) show as two unlinked rows | Not yet modeled (`work/FUTURE.md` item 2b). |

## Pointers

- `work/OVERVIEW.md` — what the app is + the institutions it tracks
- `work/NEXT.md` — what to do next session (refreshed 2026-05-18)
- `work/FUTURE.md` — full backlog with per-item plans
- `work/DECISIONS.md` — architecture decision records
- `docs/multi-currency.md` — user-facing guide to the USD/MXN model
