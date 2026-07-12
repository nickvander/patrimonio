# Frontend Deep Dive

The frontend is a Flutter application that builds for **web and Android** from one codebase, with desktop targets available from the same app. Web is the primary deployment (Dockerized, served by nginx); the Android APK talks to the same self-hosted backend over HTTPS.

## UI Architecture

Patrimonio uses a responsive dashboard shell with navigation tabs, shared API clients, and domain-specific screens for financial workflows.

### Main Screens

- **Overview**: Net worth, account balances, FX context, and high-level status.
- **Portfolio**: Holdings, allocation, performance context, and benchmark views.
- **Transactions**: Searchable transaction history with normalized descriptions and category icons.
- **Projections**: FIRE and future wealth simulations.
- **Tax Planning**: Filing-status controls, year selection, estimates, and exports.
- **Management**: Account linking, crypto connections, manual accounts, and CSV/PDF imports.

## State and Data Loading

The app keeps screen-level state close to the dashboard views and loads data through backend REST endpoints. It refreshes account, portfolio, transaction, tax, and FX views after sync/import actions.

## Visual Design

- **Theme**: Dark dashboard UI with high-contrast financial cards and charts.
- **Typography**: Inter via Google Fonts.
- **Charts**: `fl_chart` for net worth, cash flow, portfolio, and allocation visuals.
- **Responsiveness**: Layouts adapt between wide dashboard views and narrower browser widths.

## Dockerized Web Build

The frontend Dockerfile builds Flutter web assets and serves them with nginx. In the full stack, the app is available at:

```text
http://127.0.0.1:3000
```

For direct Flutter work:

```bash
cd frontend
flutter pub get
flutter analyze
flutter run -d chrome
```

## Native Android build

The same Flutter app builds an Android APK that connects to your self-hosted backend:

```bash
cd frontend
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

On **web** the API base URL is same-origin (derived from `window.location`, proxied by nginx at `/api`). A native build has no page origin, so on first launch it shows a **Settings screen** to enter the backend URL (e.g. `https://patrimonio.nickvda.com`); it's persisted on-device and can also be baked in with `--dart-define=API_BASE_URL=…`. The app is **HTTPS-only** — the backend must be served over TLS (as production is, with `COOKIE_SECURE=true`).

The app is **edge-agnostic**: a deployment behind **Cloudflare Access** enters a CF Access service token under the setup screen's *Advanced* section (sent as `CF-Access-Client-Id`/`CF-Access-Client-Secret` on every request and on the realtime WebSocket handshake); any other HTTPS front door needs only the URL. The setup screen's connection test detects a Cloudflare Access login page and prompts for the token instead of failing opaquely, and a native-only **Change server** button on the login screen reopens the setup screen. See the [Deployment guide](deployment.md#connecting-the-app-to-your-server) for the full connection matrix and the Cloudflare walkthrough.

Because browser APIs (`dart:js_interop` / `package:web`) only compile for web, every web-only capability lives behind a **conditional-import platform seam** (API client, preferences, realtime WebSocket, splash, file-drop, Plaid/passkeys). Native session auth uses a cookie-persisting `dart:io` HTTP client (the browser cookie jar has no native equivalent). Passkeys are web-only; on native, password + TOTP is the auth path. Release signing is configured via `frontend/android/key.properties` (gitignored) — see the [Deployment guide](deployment.md#android-apk).

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Web | Primary | Dockerized, served by nginx, smoke-tested locally. |
| Android | Supported | `flutter build apk` produces a signed APK; backend URL set at first run; HTTPS-only. Passkeys unavailable (password + TOTP). |
| macOS/Windows/Linux | Supported by Flutter | Native packaging is not the current deployment target. |
| iOS | Future | Shares the native seams with Android; no iOS signing/QA done yet. |
