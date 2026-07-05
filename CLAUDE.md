# patrimonio — local dev notes

## Backing services (Postgres + Redis)
Docker is **not available** on this machine, so the `docker-compose.yml` services
are run natively instead. `backend/.env` expects:

- **Postgres**: `postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio`
- **Redis**:    `redis://:patrimonio_dev@127.0.0.1:6380`

### Current data location (needs relocating)
An earlier session put the data dirs in `$HOME` instead of the project:

- Postgres data dir: `~/pgdata`  → running on port **5442**
- Redis log/data:    `~/redis`   → running on port **6380**

**Intended** location is inside this project — `.gitignore` already lists
`pgdata/`. To relocate (only when no patrimonio session is running):

```bash
# stop the app + services first, then:
pg_ctl -D ~/pgdata stop
mv ~/pgdata ~/dev/patrimonio/pgdata
pg_ctl -D ~/dev/patrimonio/pgdata -o "-p 5442 -k /tmp/pgsock" -l ~/dev/patrimonio/pgdata/pg.log start
# redis: relaunch with dir + logfile inside the project, port 6380, requirepass patrimonio_dev
```

`backend/.env` uses TCP (`127.0.0.1:5442`), so moving the data dir is transparent
to the app as long as Postgres restarts on the same port.

## Rule going forward
Never create service data dirs in `$HOME`. Persistent DBs go under this project
(gitignored); throwaway instances go in the session scratchpad. See
`~/.claude/CLAUDE.md`.
