// VM stub for the low-balance-alerts localStorage cache (see
// account_alerts_cache.dart). No localStorage on the Dart test VM: the
// seed reads empty and writes are dropped — widget tests drive the panel
// through its constructor seams instead.

Map<String, double> readCachedAccountAlerts() => <String, double>{};

void writeCachedAccountAlerts(Map<String, double> alerts) {}
