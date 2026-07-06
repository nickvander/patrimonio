# patrimonio — local dev notes

## Backing services (Postgres + Redis)
Docker is **not available** on this machine, so the `docker-compose.yml` services
are run natively instead. `backend/.env` expects:

- **Postgres**: `postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio`
- **Redis**:    `redis://:patrimonio_dev@127.0.0.1:6380`

### Data locations (relocated into the project 2026-07-06; both gitignored)
- Postgres data dir: `~/dev/patrimonio/pgdata` → port **5442**
- Redis dir/log:     `~/dev/patrimonio/redisdata` → port **6380**

Start commands (userspace, no root):

```bash
/home/nickvander/pgenv/bin/pg_ctl -D ~/dev/patrimonio/pgdata \
  -o "-p 5442 -k /tmp/pgsock -c listen_addresses=127.0.0.1" \
  -l ~/dev/patrimonio/pgdata/pg.log start
redis-server --port 6380 --requirepass patrimonio_dev --daemonize yes \
  --dir ~/dev/patrimonio/redisdata --logfile ~/dev/patrimonio/redisdata/redis.log --save ""
```

## Rule going forward
Never create service data dirs in `$HOME`. Persistent DBs go under this project
(gitignored); throwaway instances go in the session scratchpad. See
`~/.claude/CLAUDE.md`.
