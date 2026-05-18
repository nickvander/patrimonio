# Patrimonio operations runbook

This is the playbook for running a self-hosted Patrimonio install:
backups, restores, key rotation, recovery from common failure modes.
Aimed at the single-operator deployment Patrimonio is built for —
not a multi-tenant SaaS.

If you only read one section, read **[Backup setup](#backup-setup)** —
your Plaid tokens, TOTP secrets, and every transaction sit on a single
Docker volume. One `docker volume prune --force` and you start over.

---

## Backup strategy

What gets backed up:

- Every row in the `patrimonio` Postgres database. This includes the
  encrypted Plaid access tokens, the encrypted TOTP secrets, every
  transaction, every holding lot, every balance snapshot, the
  invitation tokens, the session table, the FX rate history.
- Sidecar metadata file (`.meta`) recording when the dump was taken
  and which migration head it was at.

What does NOT get backed up by this script:

- `.env` — including `ENCRYPTION_KEY`, `POSTGRES_PASSWORD`, Plaid
  credentials. **A dump without the matching `ENCRYPTION_KEY` is
  useless** — the `*_enc` columns can't be decrypted. Back `.env` up
  separately, in a different location, encrypted with a different
  passphrase.
- Redis cache. It's pure cache (FX rate lookups, session token cache,
  passkey flow state). Discardable on restore — the app rebuilds it
  on the next request.
- Docker images. Reproducible from the git repo (`docker compose
  build`). Don't waste backup space on them.

The dump itself is encrypted with **AES-256 (GPG symmetric)** using a
passphrase you choose. The cleartext SQL never touches disk — the
pipeline is `pg_dump | gpg | <file>`.

---

## Backup setup

### One-time

1. Pick a backup passphrase. This is separate from `ENCRYPTION_KEY` —
   defence in depth so a leaked `.env` doesn't trivially decrypt the
   dumps. Generate one with:

   ```bash
   openssl rand -base64 48
   ```

   Store it in a password manager. Losing it makes every backup
   unreadable.

2. Pick a backup directory. Default is `~/patrimonio-backups`.

3. Stash the passphrase in a private file the cron job can read:

   ```bash
   umask 077
   printf 'BACKUP_PASSPHRASE=%s\n' '<the-passphrase>' \
     > ~/.patrimonio-backup.env
   chmod 600 ~/.patrimonio-backup.env
   ```

   `umask 077` ensures `cat ~/.patrimonio-backup.env` from another
   user is denied.

### First manual backup

```bash
set -a; . ~/.patrimonio-backup.env; set +a
bash scripts/backup.sh
```

You should see:

```
backup: source=patrimonio-postgres-1 dest=/home/<you>/patrimonio-backups/patrimonio-20260518T154200Z.sql.gpg
backup: ok (245678 bytes)
```

The script does a round-trip decrypt of its own output before
returning success — a passphrase shell-quoting bug or a corrupt write
would fail loudly here.

### Daily cron

The host crontab (NOT in-container — the api container shouldn't have
docker socket access):

```cron
# Patrimonio nightly backup — 03:15 local, off-peak.
# Append stdout/stderr to a log file so a failed backup is debuggable
# without having to wait for the next run.
15 3 * * * set -a; . $HOME/.patrimonio-backup.env; set +a; \
           cd $HOME/patrimonio && bash scripts/backup.sh \
           >> $HOME/.patrimonio-backup.log 2>&1
```

Install with:

```bash
( crontab -l 2>/dev/null; echo '15 3 * * * set -a; . $HOME/.patrimonio-backup.env; set +a; cd $HOME/patrimonio && bash scripts/backup.sh >> $HOME/.patrimonio-backup.log 2>&1' ) | crontab -
```

Verify the next morning:

```bash
ls -la ~/patrimonio-backups/ | tail -3
tail -20 ~/.patrimonio-backup.log
```

### Retention

`BACKUP_RETENTION` controls how many most-recent dumps the script
keeps; older ones are pruned each run. Default 14 (~two weeks at one
backup per day). Set higher for monthlies:

```bash
BACKUP_RETENTION=90 bash scripts/backup.sh
```

### Off-machine copies

The local volume is one disk failure away from being useless. At
least one of the backup files should sit on different hardware:

- Sync `~/patrimonio-backups/` to a separate machine (rsync, syncthing).
- Or push to object storage (`aws s3 cp ... --sse aws:kms` —
  belt-and-suspenders since the file is already encrypted).
- Or copy the most recent dump to a USB drive on a monthly cadence.

The dump file is already encrypted — it's safe to drop on any
storage that *you* trust to be reliable, regardless of who else might
read it.

---

## Restore drill

**Run this once after setup, then quarterly.** A backup you've never
restored isn't a backup, it's a hope.

The drill restores into an **isolated compose project** (different
project name, different ports, different volumes) so the live data
stays untouched. If anything goes wrong, you throw away the test
project and try again.

### Step 1 — pick the dump to restore

```bash
ls -t ~/patrimonio-backups/patrimonio-*.sql.gpg | head -5
```

The newest one is fine for a drill. Pick a specific timestamp for a
real point-in-time restore.

### Step 2 — bring up the test project

```bash
# Use different ports so the live stack stays running.
COMPOSE_PROJECT_NAME=patrimonio-restore-test \
POSTGRES_PORT=5435 REDIS_PORT=6382 \
API_PORT=8082 FRONTEND_PORT=3002 \
docker compose -p patrimonio-restore-test up -d postgres redis
```

The api/frontend containers we leave down for now — they'd just sit
idle until we restore data for them to serve.

### Step 3 — restore into the test project

```bash
set -a; . ~/.patrimonio-backup.env; set +a
bash scripts/restore.sh \
  --project patrimonio-restore-test \
  ~/patrimonio-backups/patrimonio-20260518T154200Z.sql.gpg
```

You'll get a confirmation prompt naming the project being clobbered.
Type `yes`. After the dump replays you should see smoke counts:

```
Restore complete. Smoke counts:
  users=1
  institutions=11
  accounts=23
  transactions=4582
  ...
```

The counts should be in the same ballpark as the live DB. A `users=0`
result means the dump is empty — abort and investigate.

### Step 4 — start the api against the restored DB

```bash
COMPOSE_PROJECT_NAME=patrimonio-restore-test \
POSTGRES_PORT=5435 REDIS_PORT=6382 \
API_PORT=8082 FRONTEND_PORT=3002 \
docker compose -p patrimonio-restore-test up -d api frontend
```

### Step 5 — verify

1. API health:

   ```bash
   curl -s http://127.0.0.1:8082/api/health
   ```

   Expect `{"status":"ok","database":"connected"}`.

2. Login. Open `http://127.0.0.1:3002` and sign in with the live
   credentials. If it accepts you, sessions table + password hashes
   restored cleanly.

3. **Plaid sync** — this is the key test, because it exercises the
   `plaid_access_token_enc` decrypt path. Hit the dashboard's "Sync"
   button. If you see balances refresh, the encrypted columns
   decrypted against the live `ENCRYPTION_KEY` (which the test stack
   inherits via the same `.env`).

### Step 6 — tear down

```bash
docker compose -p patrimonio-restore-test down -v
```

The `-v` removes the test project's volumes too — the restore drill
leaves nothing behind.

### What "good" looks like

| Check | Pass |
|---|---|
| API health 200 | ✅ database connected |
| Smoke counts non-zero, matching live | ✅ schema + rows landed |
| Login succeeds | ✅ password_hash, sessions intact |
| Sync refreshes balances | ✅ `*_enc` columns decrypt with live key |

If any step fails, the dump or the `.env` is suspect. Investigate
before deleting the test project.

---

## Disaster recovery (real restore, not a drill)

Same procedure as the drill, except the project is `patrimonio` (the
live one), not the test one. The destructive step is `DROP DATABASE
patrimonio` — `scripts/restore.sh` will name the project in its
confirmation prompt, but read it carefully.

```bash
# 1. Stop the api so its connection pool can't fight us.
docker compose -p patrimonio stop api frontend

# 2. Restore over the live DB.
set -a; . ~/.patrimonio-backup.env; set +a
bash scripts/restore.sh \
  --project patrimonio \
  ~/patrimonio-backups/patrimonio-<latest>.sql.gpg

# 3. Bring api + frontend back up.
docker compose -p patrimonio up -d api frontend

# 4. Verify the dashboard loads and Sync works (same checks as the drill).
```

If `restore.sh` aborts mid-flight, the database is left in whatever
state the last successful statement reached. `DROP DATABASE` is
already committed by that point, so re-running with the same dump is
the right move — not trying to recover the half-state.

---

## ENCRYPTION_KEY rotation

You need to rotate `ENCRYPTION_KEY` when:

- The current key may have been exposed (committed to a repo, posted
  in a chat, etc.). Treat as urgent.
- As a scheduled rotation (annual is reasonable).
- Before handing the deployment to a different operator.

### Procedure

1. Generate the new key:

   ```bash
   openssl rand -hex 32
   ```

   Store it somewhere safe — you'll need it for `.env` in step 4.

2. Take a fresh backup with the OLD key still in effect. This is your
   rollback if the rotation goes wrong.

   ```bash
   set -a; . ~/.patrimonio-backup.env; set +a
   bash scripts/backup.sh
   ```

3. Run the rotation. The script stops the api, runs
   `rotate_encryption_key` in a transient container, and reports row
   counts per column:

   ```bash
   OLD_ENCRYPTION_KEY=$(grep '^ENCRYPTION_KEY=' .env | cut -d= -f2) \
   NEW_ENCRYPTION_KEY=<the new 64-hex key> \
   bash scripts/rotate-encryption-key.sh
   ```

   Expected output:

   ```
   rotate: running rotate_encryption_key…
   rotate_encryption_key: starting
     institutions.plaid_access_token_enc: 11 rows
     institutions.api_key_enc: 2 rows
     institutions.api_secret_enc: 2 rows
     institutions.api_pass_enc: 0 rows
     users.totp_secret_enc: 1 rows
   rotate_encryption_key: done (16 rows rotated)
   ```

   Each row is decrypted with OLD, re-encrypted with NEW, AND the new
   ciphertext is verified to decrypt cleanly with NEW — before the
   transaction commits. A "wrong NEW key" stops the rotation before
   any data is committed.

4. Update `.env`: replace the `ENCRYPTION_KEY=…` line with the NEW
   key, then bring the api back up:

   ```bash
   docker compose -p patrimonio up -d --force-recreate api
   ```

5. Verify end-to-end. Sign in, click Sync. A successful Plaid call
   proves the new key decrypts the Plaid access token cleanly.

6. Take a fresh backup so the new ciphertext is on disk.

7. Park the OLD key in cold storage for ≥30 days. If anything goes
   wrong post-rotation, a pre-rotation backup will still decrypt with
   it.

### What happens if you lose the old key mid-rotation

The rotation is a single transaction per column. If it aborts before
commit, nothing changed — the DB is still on the old key. You're
fine: re-run with the correct OLD key.

If it committed and you no longer have the OLD key, you've still got
the new key working — there's nothing to roll back to.

### What happens if you lose the new key after rotation

If the new key is gone AND you haven't taken a fresh backup yet,
restore the pre-rotation backup with the OLD key, then redo the
rotation with a new "new key" that you actually have.

---

## Tearing it all down

For a clean reinstall on the same machine:

```bash
docker compose -p patrimonio down -v
# All volumes gone. Pgdata, redisdata both wiped. The encrypted
# backup files in ~/patrimonio-backups/ are untouched.
```

Then either restore from backup (see [Disaster recovery](#disaster-recovery-real-restore-not-a-drill))
or `docker compose -p patrimonio up -d` for a fresh bootstrap flow.

---

## Common failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| `backup.sh`: "round-trip decrypt failed" | Passphrase had shell metacharacters that the shell mangled | Re-quote the passphrase, or stash it in a file (see [Backup setup](#one-time)) |
| `restore.sh`: "no running postgres container" | Target project's postgres is down | `docker compose -p <project> up -d postgres` |
| `restore.sh`: `psql: ERROR: ... CREATE TABLE ... already exists` | DROP DATABASE didn't complete (rare; usually a stuck connection) | Re-run; the script kills active connections before DROP |
| Restored stack: `/api/health` returns 503 | Stale connection pool on the api container | `docker compose -p <project> restart api` |
| Restored stack: Sync fails with "Failed to decrypt token" | `.env`'s `ENCRYPTION_KEY` doesn't match the one used at backup time | Update `.env` to the original key, or rotate forward |
| `rotate_encryption_key`: "decrypt failed with OLD key" | `OLD_ENCRYPTION_KEY` env var doesn't match what's actually in the DB | Re-export from `.env` — check for stray whitespace |

---

## Pointers

- `scripts/backup.sh` — implementation of the backup pipeline
- `scripts/restore.sh` — implementation of the restore pipeline
- `scripts/rotate-encryption-key.sh` — host-side rotation wrapper
- `backend/src/bin/rotate_encryption_key.rs` — the actual rotation binary
- `backend/src/services/encryption.rs` — AES-256-GCM helpers shared
  with the main app
