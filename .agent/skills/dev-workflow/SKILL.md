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

## Rebuilding after backend changes
// turbo
1. Rebuild and restart the API: `cd ~/patrimonio && docker compose up --build -d api`
// turbo
2. Watch logs for errors: `docker compose logs -f api --tail 20`
// turbo
3. Verify health: `curl -s http://localhost:8080/api/health`

## Stopping the environment
1. Stop all services: `cd ~/patrimonio && docker compose down`

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
