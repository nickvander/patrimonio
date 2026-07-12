# Patrimonio Frontend

Flutter app for Patrimonio — **web** (primary, served by nginx) and **native Android** from one codebase.

## Local Flutter Development

```bash
flutter pub get
flutter analyze
flutter run -d chrome
```

The app expects the API to be available at `http://127.0.0.1:8080` when running against the local Docker stack.

## Android APK

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

Web derives the backend URL from the page origin (same-origin `/api` proxy). A native build has no origin, so it asks for the backend URL on first launch (Settings screen, persisted) or takes `--dart-define=API_BASE_URL=https://your-host`. The app is HTTPS-only.

The setup screen also has an optional **Advanced: Cloudflare Access** section for deployments behind Cloudflare Zero Trust — paste a CF Access **service token** (Client ID + Secret) and the app sends it as `CF-Access-Client-Id`/`CF-Access-Client-Secret` on every request, WebSocket included. Deployments without Cloudflare Access just leave it empty. A **Change server** button on the native login screen reopens the setup screen. Full walkthrough (minting the token, the Service-Auth policy): [Deployment guide](../docs/deployment.md#cloudflare-access-service-token-step-by-step).

- **Web-only code stays behind conditional-import seams** (`*_web.dart` + `if (dart.library.js_interop)`), so `dart:js_interop` / `package:web` never break the Android build. When adding a browser-only capability, add a seam — don't import those libraries from a screen/service. See the flutter-frontend skill §8.
- **Release signing** is read from `android/key.properties` (gitignored → keystore under `android/keystore/`); absent that, the build falls back to debug signing. Details in the [Deployment guide](../docs/deployment.md#android-apk).
- Verify changes compile for **both** `flutter build web` and `flutter build apk`.

## Docker Web Build

From the repository root:

```bash
docker compose up --build -d frontend
```

Open `http://127.0.0.1:3000`.

The frontend Dockerfile builds Flutter web assets and serves them with nginx.
