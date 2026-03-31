---
name: dev-workflow
description: How to run, build, and test the Patrimonio development environment
---

# Dev Workflow

## Starting the environment
// turbo
1. Start all services: `cd ~/patrimonio && docker compose up -d`
// turbo
2. Verify services are healthy: `docker ps --format "table {{.Names}}\t{{.Status}}"`
// turbo
3. Test the API: `curl -s http://localhost:8080/api/health | python3 -m json.tool`

## Building and serving the Flutter frontend

**IMPORTANT: The Flutter web build takes ~50 seconds. This is normal — do NOT cancel it.**

// turbo
1. Build the web app: `cd ~/patrimonio/frontend && flutter build web --dart-define=API_BASE_URL=http://localhost:8080/api 2>&1`
   - Use `command_status` with `WaitDurationSeconds: 120` to wait for completion
   - Expected output: `✓ Built build/web` with exit code 0
// turbo
2. Kill any old server and start fresh: `pkill -f 'python3 -m http.server' 2>/dev/null; sleep 1; cd ~/patrimonio/frontend/build/web && nohup python3 -m http.server 3000 --bind 0.0.0.0 > /tmp/flutter_serve.log 2>&1 & sleep 1; curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:3000/`
   - Expected output: `HTTP 200`
3. The app is now available at `http://localhost:3000`

### Known issues
- The **browser subagent** cannot connect to localhost servers (sandbox limitation). Use `curl` to verify the server is responding, and ask the user to test in their browser.
- `flutter run -d web-server` is unreliable in this environment — always use `flutter build web` + `python3 -m http.server` instead.
- The build takes ~50s. Set `WaitMsBeforeAsync: 500` and then use `command_status` with `WaitDurationSeconds: 120` to avoid appearing stuck.

## Rebuilding after backend changes
// turbo
1. Rebuild and restart the API: `cd ~/patrimonio && docker compose up --build -d api`
// turbo
2. Watch logs for errors: `docker compose logs -f api --tail 20`
// turbo
3. Verify health: `curl -s http://localhost:8080/api/health`

## Rebuilding after frontend changes
// turbo
1. Rebuild: `cd ~/patrimonio/frontend && flutter build web --dart-define=API_BASE_URL=http://localhost:8080/api 2>&1`
   - Wait with `command_status` using `WaitDurationSeconds: 120`
// turbo
2. Restart server: `pkill -f 'python3 -m http.server' 2>/dev/null; sleep 1; cd ~/patrimonio/frontend/build/web && nohup python3 -m http.server 3000 --bind 0.0.0.0 > /tmp/flutter_serve.log 2>&1 & sleep 1; curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:3000/`

## Stopping the environment
1. Stop all services: `cd ~/patrimonio && docker compose down`
2. Stop frontend server: `pkill -f 'python3 -m http.server' 2>/dev/null`

## Running a full test cycle
// turbo
1. Rebuild everything: `cd ~/patrimonio && docker compose down && docker compose up --build -d`
// turbo
2. Wait for services: `sleep 5`
// turbo
3. Test health: `curl -s http://localhost:8080/api/health`
// turbo
4. Test accounts: `curl -s http://localhost:8080/api/accounts/summary`
// turbo
5. Test dashboard: `curl -s http://localhost:8080/api/dashboard/overview`
// turbo
6. Test exchange rates: `curl -s http://localhost:8080/api/fx/latest/USD/MXN`

## Database access
1. Connect to PostgreSQL: `docker exec -it patrimonio-postgres-1 psql -U patrimonio`
2. Useful queries:
   - List tables: `\dt`
   - Check accounts: `SELECT * FROM accounts;`
   - Check institutions: `SELECT * FROM institutions;`
   - Check exchange rates: `SELECT * FROM exchange_rates ORDER BY recorded_at DESC LIMIT 5;`
