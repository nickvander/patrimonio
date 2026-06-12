// Web implementation of the low-balance-alerts localStorage cache (see
// account_alerts_cache.dart) — a thin pass-through to Preferences, which
// is safe to import here because this file only compiles for the web/JS
// target.

import 'preferences.dart';

Map<String, double> readCachedAccountAlerts() => Preferences.getAccountAlerts();

void writeCachedAccountAlerts(Map<String, double> alerts) =>
    Preferences.setAccountAlerts(alerts);
