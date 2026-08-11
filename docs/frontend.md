# Frontend Deep Dive

The frontend is a Flutter application that builds for **web and Android** from one codebase, with desktop targets available from the same app. Web is the primary deployment (Dockerized, served by nginx); the Android APK talks to the same self-hosted backend over HTTPS.

## UI Architecture

Patrimonio uses a responsive dashboard shell with navigation tabs, shared API clients, and domain-specific screens for financial workflows. Wide layouts use a navigation rail with a static app bar; narrow layouts use a bottom bar (overflow tabs behind a **More** sheet) with a compact app bar that shows the current tab's name and scrolls away as you scroll. There is no app-bar overflow (kebab) menu — app-level settings live at the end of the Settings tab.

### Main Screens

- **Overview**: Net worth, account balances, FX context, and high-level status.
- **Portfolio**: Holdings, allocation, performance context, and benchmark views.
- **Transactions**: Searchable transaction history with normalized descriptions and category icons.
- **Cash flow**: Monthly income vs. spending, trends, and budgets.
- **Projections**: FIRE and future wealth simulations.
- **Tax planning**: Filing-status controls, year selection, estimates, and exports.
- **Lending**: Loans you hold or extend, payment schedules, and interest tracking.
- **Settings**: Account linking, crypto connections, manual accounts, CSV/PDF imports, and the app-level settings groups (language, theme, security, hidden items, sign out).

## State and Data Loading

The app keeps screen-level state close to the dashboard views and loads data through backend REST endpoints. It refreshes account, portfolio, transaction, tax, and FX views after sync/import actions.

## Visual Design

- **Theme**: Material 3 light and dark themes (system-default; switchable under Settings ➔ Preferences).
- **Typography**: Inter (UI) and JetBrains Mono (large ledger figures), bundled locally — no font CDN.
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

### Home-screen widget

The Android app ships a **home-screen widget**: net worth, the USD/MXN rate, and a sync button, each individually toggleable under *Settings → Home screen widget*. Below the numbers a sparkline plots the trend of whatever the tile's headline is — the 90-day net-worth history normally, or the 30-day rate history when the tile is configured down to FX-only (net worth renders green, the rate blue, so the two are never confusable). Two picker sizes are offered (2×1 and 3×1) and every placement is freely resizable; past two rows the roomier two-line layout takes over automatically.

The widget is **app-pushed and does no networking of its own**: it renders values the app computed on its last dashboard load, and a freshness line ("2h ago") says how old they are. Opening the app refreshes it; the sync button opens the app *and* triggers the same full sync as the in-app button. This is deliberate — the widget process never holds the session credential, and the alternative (background refresh) would require WorkManager and a second copy of the backend-connection seam for marginal gain. On Android 12+ the card chrome follows **Material You**: surfaces, text, and the icon button tint themselves from the wallpaper palette and use the system's widget corner radius, while the data accents stay fixed so a green-vs-red reading keeps its meaning.


Because browser APIs (`dart:js_interop` / `package:web`) only compile for web, every web-only capability lives behind a **conditional-import platform seam** (API client, preferences, realtime WebSocket, splash, file-drop, Plaid/passkeys). Native session auth uses a cookie-persisting `dart:io` HTTP client (the browser cookie jar has no native equivalent). Passkeys work on web **and** Android: the native seam performs real WebAuthn ceremonies through Android's Credential Manager (Google Password Manager passkeys and USB/NFC security keys), which needs `ANDROID_APK_CERT_SHA256` set server-side — see the [Deployment guide](deployment.md#native-passkeys-android). Bank linking is also platform-aware: the app sends its platform with link-token requests so the backend issues an Android OAuth-capable Plaid token (see [Plaid OAuth from the Android app](deployment.md#plaid-oauth-from-the-android-app)). Release signing is configured via `frontend/android/key.properties` (gitignored) — see the [Deployment guide](deployment.md#android-apk).

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Web | Primary | Dockerized, served by nginx, smoke-tested locally. |
| Android | Supported | `flutter build apk` produces a signed APK; backend URL set at first run; HTTPS-only. Passkeys via Credential Manager (needs `ANDROID_APK_CERT_SHA256` + asset links server-side). |
| macOS/Windows/Linux | Supported by Flutter | Native packaging is not the current deployment target. |
| iOS | Future | Shares the native seams with Android; no iOS signing/QA done yet. |
