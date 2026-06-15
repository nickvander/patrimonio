/// Pure helpers for the manual-sync progress indicator on the dashboard.
///
/// Extracted from the dashboard build closure so the counting logic is unit
/// testable (the dashboard screen itself is too large/stateful to widget-test
/// directly). The dashboard polls /sync-status while a sync runs and feeds the
/// rows through these to drive the "Updating… (done of total)" label.

/// Institution `integration_type`s that actually sync. Manual / CSV / PDF
/// institutions are skipped server-side, so they're excluded from the progress
/// total (otherwise the count could never reach 100%).
const Set<String> kSyncableInstitutionTypes = {
  'plaid',
  'coinbase',
  'coinbase_oauth',
};

/// Number of institutions that will really sync — the denominator of the
/// "(done of total)" progress. Tolerant of nulls / malformed rows.
int syncableInstitutionCount(List<dynamic>? syncData) {
  if (syncData == null) return 0;
  return syncData
      .where((i) =>
          i is Map &&
          kSyncableInstitutionTypes
              .contains((i['integration_type'] ?? '').toString()))
      .length;
}

/// How many institutions have finished since [startedAt] — an institution
/// counts as done once its `last_synced_at` advances past the moment the sync
/// was kicked off. Errored institutions don't bump `last_synced_at`, so they
/// won't count; the awaited sync call is the source of truth for completion.
int syncedSinceCount(List<dynamic>? syncData, DateTime startedAt) {
  if (syncData == null) return 0;
  return syncData.where((i) {
    if (i is! Map) return false;
    final ts = DateTime.tryParse(i['last_synced_at']?.toString() ?? '');
    return ts != null && ts.isAfter(startedAt);
  }).length;
}
