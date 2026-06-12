// Platform seam for the localStorage-backed low-balance-alerts cache.
//
// AccountTransactionsScreen seeds its alert thresholds from
// `Preferences.getAccountAlerts()` (and writes back on save), but
// `Preferences` wraps `window.localStorage` via `package:web`, which only
// compiles for the web/JS target — importing it directly made the panel
// (and therefore any widget test that pumps it) impossible to compile
// under the Dart test VM (`flutter test`). Same pattern as
// services/api_platform.dart and utils/url_opener.dart: the conditional
// export resolves to the real Preferences-backed implementation in a
// browser build and to an empty/no-op stub on the VM (tests never rely on
// the localStorage seed — the server-side `_hydrateAlerts` path is the
// source of truth anyway).
export 'account_alerts_cache_stub.dart'
    if (dart.library.js_interop) 'account_alerts_cache_web.dart';
