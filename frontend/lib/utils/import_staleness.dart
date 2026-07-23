/// Staleness logic for import-only (manual) institutions.
///
/// The backend stamps each manual account in `/api/dashboard/overview` with
/// `last_data_at` — when data last arrived (import confirm / manual balance
/// edit / last transaction INSERT). Synced accounts (Plaid, exchanges) omit
/// the field: their freshness is the institution sync status, handled by
/// [SyncErrorBanner]. Pure functions here so the grouping/threshold rules are
/// unit-testable without widgets.
library;

/// Default reminder threshold (days) when the user hasn't configured one.
/// Mirrors the backend's `DEFAULT_STALENESS_DAYS`.
const int kDefaultImportStaleDays = 30;

/// `app_settings` key for the user-adjustable threshold. Mirrors the
/// backend's `STALENESS_SETTING_KEY` — the daily notification sweep reads
/// the same key, so the banner and the bell always agree.
const String kImportStaleDaysSettingKey = 'import_staleness_days';

/// Parse the raw `app_settings` value into a usable threshold: absent /
/// non-numeric → default 30; numeric values clamped to 1..365 (matches the
/// backend clamp so client and server never disagree on what "stale" means).
int staleThresholdFrom(dynamic raw) {
  if (raw is num) return raw.toInt().clamp(1, 365);
  return kDefaultImportStaleDays;
}

/// When data last arrived for [account], or null for synced accounts /
/// unparseable timestamps. Only manual accounts carry `last_data_at`, so a
/// non-null result implies "this balance came from an import or hand edit".
DateTime? accountLastDataAt(dynamic account) {
  if (account is! Map) return null;
  final raw = account['last_data_at'];
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

/// Whole days since [account]'s data last moved, or null when unknown.
/// Clock skew guard: a server timestamp slightly in the future reads as 0,
/// never negative.
int? accountDataAgeDays(dynamic account, {DateTime? now}) {
  final last = accountLastDataAt(account);
  if (last == null) return null;
  final days = (now ?? DateTime.now()).toUtc().difference(last.toUtc()).inDays;
  return days < 0 ? 0 : days;
}

/// One import-only institution whose newest data is past the threshold.
class StaleImportInstitution {
  final String name;

  /// Days since ANY of its accounts last received data (freshest wins —
  /// one recent import keeps the whole institution off the banner).
  final int daysStale;

  const StaleImportInstitution({required this.name, required this.daysStale});
}

/// Group [accounts] (the overview payload) by institution and return the
/// import-only institutions whose freshest account is at least
/// [thresholdDays] old, most-stale first. Accounts without `last_data_at`
/// (synced integrations) never contribute.
List<StaleImportInstitution> staleImportInstitutions(
  List<dynamic> accounts, {
  required int thresholdDays,
  DateTime? now,
}) {
  // Per-institution MINIMUM age: the freshest account defines the
  // institution's staleness, mirroring the backend's MAX(last_data_at).
  final freshestAge = <String, int>{};
  for (final acc in accounts) {
    if (acc is! Map) continue;
    if ((acc['integration_type'] ?? '').toString() != 'manual') continue;
    final age = accountDataAgeDays(acc, now: now);
    if (age == null) continue;
    final inst = (acc['institution_name'] ?? '').toString().trim();
    if (inst.isEmpty) continue;
    final prev = freshestAge[inst];
    if (prev == null || age < prev) freshestAge[inst] = age;
  }
  final stale = freshestAge.entries
      .where((e) => e.value >= thresholdDays)
      .map((e) => StaleImportInstitution(name: e.key, daysStale: e.value))
      .toList()
    ..sort((a, b) => b.daysStale.compareTo(a.daysStale));
  return stale;
}
