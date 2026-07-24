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

/// `app_settings` key for per-institution banner snoozes: a JSON object
/// mapping institution id → `{"until": iso8601, "data_as_of": iso8601}`.
/// Written by the banner's dismiss (×); read by the backend's daily
/// notification sweep (`STALENESS_SNOOZE_SETTING_KEY`) so a dismissed
/// institution is silent in the bell too.
const String kImportStaleSnoozesSettingKey = 'import_staleness_snoozes';

/// `app_settings` key for permanently muted institutions: a JSON array of
/// institution id strings ("Remind me" off in Settings). Mirrors the
/// backend's `STALENESS_MUTE_SETTING_KEY`. Muting silences banner + bell
/// only — the accounts-list "as of" chips deliberately stay.
const String kImportStaleMutedSettingKey = 'import_staleness_muted';

/// How long a banner dismiss silences the listed institutions.
const Duration kImportStaleSnoozeWindow = Duration(days: 7);

/// One institution's dismiss window, parsed from
/// [kImportStaleSnoozesSettingKey].
class ImportStaleSnooze {
  /// Reminders stay hidden until this instant (dismiss time + 7 days).
  final DateTime until;

  /// The institution's freshest `last_data_at` at dismiss time. Data newer
  /// than this means a fresh import happened after the dismiss — a new
  /// staleness episode, which invalidates the snooze immediately.
  final DateTime? dataAsOf;

  const ImportStaleSnooze({required this.until, this.dataAsOf});

  /// Whether this snooze hides an institution whose newest data landed at
  /// [lastDataAt], evaluated at [now]. Mirrors the backend's
  /// `StalenessSnooze::suppresses` (including the 1s tolerance that keeps
  /// ISO-8601 round-tripping from spuriously un-snoozing).
  bool suppresses(DateTime? lastDataAt, DateTime now) {
    if (!now.isBefore(until)) return false;
    final asOf = dataAsOf;
    if (asOf == null || lastDataAt == null) return true;
    return !lastDataAt.isAfter(asOf.add(const Duration(seconds: 1)));
  }

  Map<String, String> toJson() => {
        'until': until.toUtc().toIso8601String(),
        if (dataAsOf != null)
          'data_as_of': dataAsOf!.toUtc().toIso8601String(),
      };
}

/// Parse the raw [kImportStaleSnoozesSettingKey] value. Tolerant: non-map
/// roots and entries without a parseable `until` are dropped, so corrupt
/// data expires instead of muting forever (same policy as the backend).
Map<String, ImportStaleSnooze> staleSnoozesFrom(dynamic raw) {
  final out = <String, ImportStaleSnooze>{};
  if (raw is! Map) return out;
  raw.forEach((key, entry) {
    if (entry is! Map) return;
    final until = DateTime.tryParse((entry['until'] ?? '').toString());
    if (until == null) return;
    out[key.toString()] = ImportStaleSnooze(
      until: until.toUtc(),
      dataAsOf:
          DateTime.tryParse((entry['data_as_of'] ?? '').toString())?.toUtc(),
    );
  });
  return out;
}

/// Parse the raw [kImportStaleMutedSettingKey] value (JSON array of
/// institution id strings) into a set. Non-list roots → empty.
Set<String> staleMutedFrom(dynamic raw) {
  if (raw is! List) return <String>{};
  return raw
      .map((e) => e.toString())
      .where((s) => s.isNotEmpty)
      .toSet();
}

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
  /// Institution id from the overview payload — the stable key snooze and
  /// mute entries are stored under. Empty when the backend predates the
  /// `institution_id` field (then the name is the grouping key).
  final String institutionId;

  final String name;

  /// Days since ANY of its accounts last received data (freshest wins —
  /// one recent import keeps the whole institution off the banner).
  final int daysStale;

  /// When the freshest account last received data. Written into a snooze's
  /// `data_as_of` on dismiss so a later import invalidates the snooze.
  final DateTime? lastDataAt;

  const StaleImportInstitution({
    required this.name,
    required this.daysStale,
    this.institutionId = '',
    this.lastDataAt,
  });
}

/// Group [accounts] (the overview payload) by institution and return the
/// import-only institutions whose freshest account is at least
/// [thresholdDays] old, most-stale first. Accounts without `last_data_at`
/// (synced integrations) never contribute.
///
/// [muted] institutions (Settings "Remind me" off) are always excluded;
/// [snoozes] entries hide their institution while
/// [ImportStaleSnooze.suppresses] holds — i.e. until the 7-day window
/// lapses or a fresh import lands, whichever comes first. Both are keyed
/// by institution id.
List<StaleImportInstitution> staleImportInstitutions(
  List<dynamic> accounts, {
  required int thresholdDays,
  Map<String, ImportStaleSnooze> snoozes = const {},
  Set<String> muted = const {},
  DateTime? now,
}) {
  // Per-institution FRESHEST data: the freshest account defines the
  // institution's staleness, mirroring the backend's MAX(last_data_at).
  final byKey = <String, ({String id, String name, int age, DateTime? last})>{};
  for (final acc in accounts) {
    if (acc is! Map) continue;
    if ((acc['integration_type'] ?? '').toString() != 'manual') continue;
    final age = accountDataAgeDays(acc, now: now);
    if (age == null) continue;
    final name = (acc['institution_name'] ?? '').toString().trim();
    final id = (acc['institution_id'] ?? '').toString().trim();
    // Prefer the stable id as the grouping key; fall back to the name for
    // payloads from an older backend without `institution_id`.
    final key = id.isNotEmpty ? id : name;
    if (key.isEmpty) continue;
    final prev = byKey[key];
    if (prev == null || age < prev.age) {
      byKey[key] =
          (id: id, name: name, age: age, last: accountLastDataAt(acc));
    }
  }
  final clock = (now ?? DateTime.now()).toUtc();
  final stale = byKey.values
      .where((e) => e.age >= thresholdDays)
      .where((e) => !muted.contains(e.id))
      .where((e) => !(snoozes[e.id]?.suppresses(e.last, clock) ?? false))
      .map((e) => StaleImportInstitution(
            institutionId: e.id,
            name: e.name,
            daysStale: e.age,
            lastDataAt: e.last,
          ))
      .toList()
    ..sort((a, b) => b.daysStale.compareTo(a.daysStale));
  return stale;
}
