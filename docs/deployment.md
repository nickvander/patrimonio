# Deployment & Infrastructure

Patrimonio is designed to run locally with Docker Compose and to deploy as a static Flutter web frontend plus a stateless Rust API.

## Local Development

### Prerequisites

- Docker and Docker Compose
- Optional Plaid credentials for US account linking
- Optional Coinbase and Bitso credentials for crypto sync
- Optional ExchangeRate-API key for live FX data
- `ENCRYPTION_KEY` configured in `.env` before storing integration tokens or API secrets

For real Plaid users, also configure the Plaid dashboard environment, product access, and deployed HTTPS redirect/webhook URLs. Sandbox credentials are enough for local test data only.

### Start the Stack

```bash
cp .env.example .env
docker compose up --build -d
```

This starts:

| Service | Container role | Host URL/port |
|---------|----------------|---------------|
| Frontend | Flutter web build served by nginx | `http://127.0.0.1:3000` |
| API | Rust/Axum server | `http://127.0.0.1:8080` |
| PostgreSQL | Primary database | `127.0.0.1:5433` |
| Redis | Cache for FX and short-lived data | `127.0.0.1:6380` |

The non-default Postgres and Redis host ports reduce conflicts with other local services.

### Common Commands

```bash
docker compose ps
docker compose logs -f api
docker compose up --build -d frontend
docker compose down
```

### Smoke Test

```bash
NODE_PATH=/path/to/node_modules ./scripts/smoke.cjs
```

The smoke test checks API health and uses Playwright to confirm the Flutter app renders in a browser. Use `SKIP_BROWSER=1 ./scripts/smoke.cjs` when browser dependencies are unavailable and API-only validation is enough.

### Setup Status

The API exposes `GET /api/setup/status` for launch readiness checks. The Management tab uses it to show whether Plaid credentials and `ENCRYPTION_KEY` are configured before enabling real account linking.

## Production Shape

A production deployment should keep the same service boundaries:

- **Frontend**: Flutter web build hosted by Firebase Hosting, Cloud Storage/CDN, or any static container host.
- **API**: Rust container on Cloud Run or another stateless container platform.
- **Database**: Managed PostgreSQL such as Cloud SQL.
- **Cache**: Managed Redis such as Memorystore.
- **Secrets**: Store Plaid, Coinbase, Bitso, FX, and encryption settings in the platform secret manager.
- **Backups**: Enable scheduled database backups before connecting real financial data.

## VPS deployment (single-host)

The minimum production target supported out of the box is "one Linux
VPS running `docker compose` behind nginx with Let's Encrypt." This is
the shape needed for Plaid Production: Plaid's egress has to be able
to reach `/api/institutions/webhook` at a public HTTPS URL.

### 1. Provision the host

- A small VPS (1 vCPU / 2 GB RAM is enough for a single-household
  deployment). Open ports 22, 80, and 443. Keep port 8080 closed to
  the public — nginx proxies to it on the loopback only.
- Install Docker + the Compose plugin, nginx, and certbot.
- Clone the repo, copy `.env.example` → `.env`, and fill in:
  - `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV=production`.
  - `ENCRYPTION_KEY` (a strong, persisted random 32-byte key —
    `openssl rand -base64 32`; rotating this is a separate runbook in
    `operations.md`).
  - `FRONTEND_BASE_URL=https://patrimonio.example.com`.
  - `PLAID_WEBHOOK_URL=https://patrimonio.example.com/api/institutions/webhook`.
  - `TRUSTED_PROXY_CIDRS=127.0.0.1/32` (the nginx loopback address —
    add the docker bridge if nginx runs in a container).
  - DB / Redis URLs can stay on the defaults if the compose stack
    runs on the same host.

### 2. nginx + Let's Encrypt

A working sample for `patrimonio.example.com` (replace the hostname
and the TLS paths once certbot emits them):

```nginx
server {
    listen 80;
    server_name patrimonio.example.com;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name patrimonio.example.com;

    ssl_certificate     /etc/letsencrypt/live/patrimonio.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/patrimonio.example.com/privkey.pem;

    client_max_body_size 25m;     # PDF imports can run several MB
    proxy_read_timeout 120s;       # Plaid syncs occasionally take time

    # API
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Frontend static
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
    }
}
```

Issue the cert once:

```bash
sudo certbot certonly --webroot -w /var/www/certbot \
    -d patrimonio.example.com -m you@example.com --agree-tos
sudo systemctl reload nginx
```

certbot installs a renewal timer by default; verify with
`systemctl list-timers | grep certbot`.

### 3. Trusted proxy IPs

The API ignores `X-Forwarded-For` / `X-Real-IP` from any peer that
isn't in `TRUSTED_PROXY_CIDRS`. With the compose stack on the same
host as nginx, the API sees connections from the docker bridge or
loopback. The simplest correct value is:

```
TRUSTED_PROXY_CIDRS=127.0.0.1/32,172.16.0.0/12
```

The `172.16.0.0/12` block covers the default docker0 + compose
networks. If you've customized the bridge, set it to the actual
gateway IP — `docker network inspect patrimonio_default` shows it.

Without this, audit-log `ip_address` stays NULL because XFF gets
stripped at the API layer. With it set correctly, audit rows show
the real client IP again.

### 4. Plaid webhook activation

Plaid binds the webhook URL to each item *at link time* — items
linked before `PLAID_WEBHOOK_URL` was configured keep polling
forever.

After the first time you set the env var on a deployment that
already has linked items, choose one of:

- **Re-link an institution**: opens Plaid Link, exchanges a new
  token, and the new webhook URL takes effect for that item.
- **One-shot update (preferred for ≥ 1 institution)**: the API
  exposes `POST /api/institutions/update-webhook`. It iterates
  every Plaid item the caller owns and calls Plaid's
  `/item/webhook/update` with the configured URL. Returns a
  per-institution result list — confirm `updated` matches the
  number of items you expect.

  ```bash
  curl -X POST https://patrimonio.example.com/api/institutions/update-webhook \
       -H 'Cookie: patrimonio_session=...' \
       -H 'X-Requested-With: patrimonio' | jq .
  ```

  The Management tab also surfaces the "Webhook URL configured"
  card from `GET /api/setup/status`.

Once the URL is registered, Plaid pushes `INITIAL_UPDATE`,
`DEFAULT_UPDATE`, `TRANSACTIONS_REMOVED`, and `ITEM_ERROR` events.
The receiver in `backend/src/api/institutions.rs::plaid_webhook`
ES256-verifies every request before doing anything, so an
unauthenticated POST to that path is a no-op.

### 5. Log rotation

`docker compose up -d` does *not* rotate container logs by default —
they accumulate in `/var/lib/docker/containers/<id>/<id>-json.log`
until the disk fills.

Add the `logging` block to each service in `docker-compose.yml`:

```yaml
services:
  api:
    # ...
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
```

Or set a daemon-wide default in `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
```

(Daemon-wide setting applies to newly-started containers — restart
the stack after changing it.)

### 6. Backups

`docs/operations.md` documents the encrypted nightly backup +
restore drill. The TL;DR for a new VPS:

- Make sure `BACKUP_S3_BUCKET` (or an equivalent off-host target)
  is reachable from the host. Local-disk-only backups don't survive
  a host loss.
- Run the bootstrap restore drill on day one; the runbook walks
  through verifying encryption, restoring into a fresh database,
  and rotating the encryption key.

### 7. Health checks + restart policy

The compose file already sets `restart: unless-stopped` on every
service. Pair that with a small uptime check (any external
monitor that hits `https://patrimonio.example.com/api/health` every
few minutes) so a wedged container surfaces as a notification
rather than via "the app feels slow."

## Continuous Integration

Recommended CI checks:

1. `cargo test` for backend logic.
2. `flutter analyze` and `flutter build web` for frontend health.
3. `docker compose build` to catch container packaging issues.
4. `mkdocs build` for documentation.
5. `scripts/smoke.cjs` in an environment with browser dependencies.

### Documentation Build

```bash
pip install mkdocs-material
mkdocs serve
```
