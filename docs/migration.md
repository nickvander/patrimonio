# Migrating to a new server (homelab)

Moving Patrimonio to a new box — say from a laptop/VPS to a homelab — keeps
**all your data and all your linked accounts**, including Plaid, with no
re-linking. The trick is that the Plaid access tokens (and TOTP / Coinbase
secrets) are encrypted in Postgres with a key that is **not** machine-bound:
it's just the `ENCRYPTION_KEY` env var. Carry the database dump *and* that key
and everything decrypts on the new box.

> The single most important rule: **a database dump without the matching
> `ENCRYPTION_KEY` is useless.** Every `*_enc` column (Plaid tokens, TOTP
> secrets, Coinbase tokens) is AES-256-GCM encrypted under that key. Lose it
> and those accounts must be re-linked from scratch. Store it offline before
> you start.

## What has to travel

Run this on the **old** box to get a categorized checklist of exactly what to
copy (it only prints to your terminal, never to a file):

```bash
bash scripts/migrate-secrets.sh        # reads ./.env
```

It splits your `.env` into two groups:

**Carry verbatim** (must match on the new box, or data breaks):

- `ENCRYPTION_KEY` — **critical.** Decrypts Plaid/TOTP/Coinbase tokens.
- `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV` — Plaid only syncs items
  from the same environment they were linked in (`sandbox` / `production`).
- `COINBASE_CLIENT_ID` / `COINBASE_CLIENT_SECRET`, `EXCHANGE_RATE_API_KEY`.
- `BACKUP_PASSPHRASE` — needed to decrypt the backup you carry over.

**Change for the new host** (don't copy blindly — they encode the hostname):

- `FRONTEND_BASE_URL`, `ALLOWED_ORIGINS` — the new URL the browser uses.
- `PLAID_REDIRECT_URI`, `PLAID_WEBHOOK_URL`, `COINBASE_REDIRECT_URI` — point
  at the new host **and re-register them in the Plaid / Coinbase dashboards**
  (OAuth banks reject an unregistered redirect URI).
- `POSTGRES_PASSWORD` / `REDIS_PASSWORD` can be regenerated, as long as
  `DATABASE_URL` / `REDIS_URL` on the new box match what compose creates.

## Step by step

### 1. On the OLD box — take a fresh, complete backup

```bash
BACKUP_PASSPHRASE='<from your password manager>' bash scripts/backup.sh
```

This writes an encrypted `pg_dump` (`*.sql.gpg`) to `~/patrimonio-backups`
(see [operations.md](operations.md) for details). Copy the newest file to the
new box (USB, `scp`, syncthing — anything).

Also save the `migrate-secrets.sh` output (the "carry verbatim" block) and your
`ENCRYPTION_KEY` to your password manager **now**, before you decommission the
old box.

### 2. On the NEW box — get the code + env in place

```bash
git clone <your patrimonio remote> && cd patrimonio
cp .env.example .env
```

Edit `.env`:

- Paste the **carry-verbatim** values (`ENCRYPTION_KEY`, `PLAID_*`,
  `COINBASE_*`, `EXCHANGE_RATE_API_KEY`).
- Set the **change-for-host** values to the new hostname
  (`FRONTEND_BASE_URL`, `ALLOWED_ORIGINS`, `PLAID_REDIRECT_URI`, …).
- Set fresh `POSTGRES_PASSWORD` / `REDIS_PASSWORD` if you like, and make sure
  `DATABASE_URL` / `REDIS_URL` reference them.

Bring up just the datastores so there's an empty DB to restore into:

```bash
docker compose -p patrimonio up -d postgres redis
```

### 3. On the NEW box — restore the dump

```bash
BACKUP_PASSPHRASE='<same passphrase>' bash scripts/restore.sh <the-dump>.sql.gpg
```

`restore.sh` drops and recreates the DB, then replays the dump with
`ON_ERROR_STOP` so a half-applied restore can't slip through.

### 4. Start the app and verify the tokens decrypted

```bash
docker compose -p patrimonio up -d api frontend
```

Open the app, log in (your **password, TOTP, passkeys, and recovery codes all
came over in the dump** — same credentials as before), and click **Sync**. If
balances refresh, the Plaid tokens decrypted against the carried
`ENCRYPTION_KEY` — the migration worked end to end.

### 5. Re-point Plaid for the new hostname

- In the [Plaid dashboard](https://dashboard.plaid.com), add the new
  `PLAID_REDIRECT_URI` to the allowed redirect URIs (OAuth banks need it).
- If you use webhooks, set `PLAID_WEBHOOK_URL` to the new host and run the
  one-shot updater so existing items point at it:

  ```
  POST /api/institutions/update-webhooks    # authenticated; updates all items
  ```

  Without a webhook URL, Plaid falls back to periodic polling — fine, just less
  real-time.

## Gotchas

- **`PLAID_ENV` mismatch** is the most common failure: an item linked in
  `production` cannot sync against `sandbox` and vice-versa. Keep it identical.
- **Redis is a cache, not state** — don't bother migrating its volume; a fresh
  empty Redis is correct.
- **Cursors come along** in the dump (`institutions.plaid_transactions_cursor`),
  so syncs resume incrementally rather than re-pulling all history.
- **HTTPS / same-origin**: OAuth banks need the API reachable same-origin over
  HTTPS. On a homelab that usually means a reverse proxy (Caddy/nginx/Traefik)
  terminating TLS in front of the frontend + `/api`. See the OAuth notes in
  [deployment.md](deployment.md).

## If you get locked out (break-glass)

You can't be permanently locked out of a box you control. If you forget the
password, lose your recovery codes, *and* lose your TOTP device, run the
offline admin CLI directly against Postgres on the new host:

```bash
DATABASE_URL='postgres://patrimonio:<pw>@127.0.0.1:5433/patrimonio' \
  cargo run --bin admin_reset -- reset-password
```

It can also `disable-totp`, regenerate `recovery-codes`, `reactivate` a
disabled account, and `revoke-sessions`. Every action is logged to
`auth_audit`. Run `admin_reset -- list` first to see your users. Because the
only "credential" is shell + DB access, keep the box itself secured.

> **Do this on day one of the homelab:** from Settings, regenerate your
> recovery codes and store them offline, and register a passkey (your phone's
> biometric). That's a second and third way back in before you ever need the
> CLI.
