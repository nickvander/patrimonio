/// Default derivation for the mobile quick-entry sheet
/// (`widgets/quick_entry_sheet.dart`).
///
/// Quick entry is only fast because the fields are already right, so the
/// derivation carries the whole feature — and a fast path that silently
/// guesses wrong is worse than a slow one. Two rules follow from that and
/// are enforced by the sheet: every value derived here is RENDERED in the
/// sheet (never applied invisibly) and every one is overridable there.
///
/// Kept as pure functions in `utils/` (house rule) so the derivation can
/// be unit-tested against real transaction-payload shapes without pumping
/// a widget.
library;

import 'category.dart';

/// Transaction rows the user typed in themselves. The Plaid/CSV/split
/// rows in the same payload say nothing about where the user chooses to
/// book CASH, which is the only thing quick entry is defaulting for.
bool _isManual(Map<dynamic, dynamic> row) =>
    (row['source'] ?? '').toString().trim().toLowerCase() == 'manual';

/// Sort key for "most recently ADDED", which is deliberately NOT the
/// posted `date`: a cash row typed today for last Friday is still the
/// user's latest entry, and `created_at` (the insert instant the
/// transactions payload carries) is the only field that says so. Falls
/// back to the posted date when `created_at` is absent or unparseable,
/// and to epoch zero when both are.
DateTime _addedAt(Map<dynamic, dynamic> row) {
  final created = DateTime.tryParse((row['created_at'] ?? '').toString());
  if (created != null) return created;
  final posted = DateTime.tryParse((row['date'] ?? '').toString());
  return posted ?? DateTime.fromMillisecondsSinceEpoch(0);
}

/// Manual rows in [transactions], newest-added first. The payload is
/// already ordered by posted date, which is a different order — sort
/// explicitly rather than trusting the caller's list.
List<Map<dynamic, dynamic>> _manualNewestFirst(List<dynamic> transactions) {
  final rows = <Map<dynamic, dynamic>>[
    for (final t in transactions)
      if (t is Map && _isManual(t)) t,
  ];
  rows.sort((a, b) => _addedAt(b).compareTo(_addedAt(a)));
  return rows;
}

/// Id of the account the user most recently added a MANUAL transaction
/// to, restricted to accounts still present in [accounts] (a closed or
/// unlinked account must not become the default).
///
/// Returns null when the history holds no usable manual row — a first-run
/// user, or an account list that no longer contains the one they used.
/// The sheet then falls back to the Add-transaction dialog's own default
/// (first non-credit account), so the two flows never disagree about
/// where an entry lands.
String? lastManualAccountId(
  List<dynamic> transactions,
  List<dynamic> accounts,
) {
  final known = <String>{
    for (final a in accounts)
      if (a is Map && a['id'] != null) a['id'].toString(),
  };
  for (final row in _manualNewestFirst(transactions)) {
    final id = row['account_id']?.toString();
    if (id != null && id.isNotEmpty && known.contains(id)) return id;
  }
  return null;
}

/// Categories the user most recently booked a MANUAL transaction against,
/// most-recently-used first, deduped case-insensitively (first spelling
/// wins) and capped at [limit]. These become the sheet's one-tap chips,
/// which is why order is recency and NOT the alphabetical order
/// [distinctPrettyCategories] uses — a scroll-to-find list is the thing
/// quick entry exists to replace.
///
/// Rows with no category at all are skipped: [prettyCategory] renders
/// those as the "Uncategorized" / "Sin categoría" SENTINEL, and offering
/// that as a one-tap chip would persist a placeholder as a real category.
///
/// [fallback] (typically the host's `distinctPrettyCategories` over all
/// sources) pads the tail so a user who has never used quick entry still
/// gets chips instead of an empty row; padding preserves the fallback's
/// own order and never displaces a recently-used entry.
List<String> recentManualCategories(
  List<dynamic> transactions, {
  List<String> fallback = const [],
  int limit = 6,
}) {
  final out = <String>[];
  final seen = <String>{};
  void add(String raw) {
    final label = raw.trim();
    if (label.isEmpty || out.length >= limit) return;
    if (seen.add(label.toLowerCase())) out.add(label);
  }

  for (final row in _manualNewestFirst(transactions)) {
    final user = (row['user_category'] ?? '').toString().trim();
    final detailed = (row['category_detailed'] ?? '').toString().trim();
    final primary = (row['category'] ?? '').toString().trim();
    // No raw category anywhere → prettyCategory would hand back the
    // sentinel; skip rather than offer it.
    if (user.isEmpty && detailed.isEmpty && primary.isEmpty) continue;
    add(
      prettyCategory(userCategory: user, detailed: detailed, primary: primary),
    );
    if (out.length >= limit) return out;
  }
  for (final f in fallback) {
    add(f);
    if (out.length >= limit) break;
  }
  return out;
}
