# Frontend Deep Dive

The frontend is a Flutter application focused on the web build today, with the codebase structured so desktop and mobile targets can continue to evolve from the same app.

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

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Web | Primary | Dockerized and smoke-tested locally. |
| macOS/Windows/Linux | Supported by Flutter | Native packaging is not the current deployment target. |
| Android/iOS | Future hardening | Responsive layouts exist, but production mobile QA remains future work. |
