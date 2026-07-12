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

**IMPORTANT: The Flutter web build takes ~50 seconds and generates no stdout until the very end, which looks like freezing.**

// turbo
1. Build the web app in the background, piping output to a log so we don't block the UI: `cd ~/patrimonio/frontend && flutter build web -v --dart-define=API_BASE_URL=http://localhost:8080/api > /tmp/flutter_build.log 2>&1 &`
   - **Immediately instruct the user** that the build is running in the background and tell them to run `tail -f /tmp/flutter_build.log` in their VS Code terminal to see live progress.
   - Do not wait synchronously for this step if it blocks your conversational thread too long.
// turbo
2. Once the build finishes, kill any old server and start fresh: `pkill -f 'python3 -m http.server' 2>/dev/null; sleep 1; cd ~/patrimonio/frontend/build/web && nohup python3 -m http.server 3000 --bind 0.0.0.0 > /tmp/flutter_serve.log 2>&1 & sleep 1; curl -s -o /dev/null -w 'HTTP %{http_code}' http://localhost:3000/`
   - Expected output: `HTTP 200`
3. The app is now available at `http://localhost:3000`

### Known issues
- The **browser subagent** cannot connect to localhost servers (sandbox limitation). Use `curl` to verify the server is responding, and ask the user to test in their browser.
- `flutter run -d web-server` is unreliable in this environment — always use `flutter build web` + `python3 -m http.server` instead.

## Building the Android APK

The frontend also builds a native **Android APK** (same codebase; web-only code
is behind conditional-import seams — see the flutter-frontend skill §8). The
Android SDK is at `~/android-sdk` (`ANDROID_HOME`); `flutter build apk` works on
this VM.

// turbo
1. Build the signed release APK: `cd ~/patrimonio/frontend && flutter build apk --release`
   - Output: `build/app/outputs/flutter-apk/app-release.apk` (~70 MB).
   - Release signing is read from `frontend/android/key.properties` (gitignored,
     points at the gitignored keystore under `android/keystore/`). If that file
     is absent (fresh clone / CI), the build falls back to debug signing so it
     still succeeds — it just isn't signed with the real upload key. **Back up
     the keystore + `key.properties`; losing them means you can't update an
     installed app.**
2. Bake in a default backend URL (optional): add
   `--dart-define=API_BASE_URL=https://patrimonio.nickvda.com`. Otherwise the app
   asks for the backend URL on first launch (Settings screen) and remembers it.
3. Install: push the APK to the phone and sideload it. The app is **HTTPS-only**
   (network security config); the backend must be reachable over TLS.

Verify a change compiles for **both** targets before calling it done —
`flutter build web` and `flutter build apk`. A stray `package:web` import breaks
only the APK, and `flutter analyze` won't catch it.

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
