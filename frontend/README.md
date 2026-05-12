# Patrimonio Frontend

Flutter web dashboard for Patrimonio.

## Local Flutter Development

```bash
flutter pub get
flutter analyze
flutter run -d chrome
```

The app expects the API to be available at `http://127.0.0.1:8080` when running against the local Docker stack.

## Docker Web Build

From the repository root:

```bash
docker compose up --build -d frontend
```

Open `http://127.0.0.1:3000`.

The frontend Dockerfile builds Flutter web assets and serves them with nginx.
