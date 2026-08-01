/// Pure helpers for the manual-sync progress indicator on the dashboard.
///
/// Extracted from the dashboard build closure so the counting logic is unit
/// testable (the dashboard screen itself is too large/stateful to widget-test
/// directly). The dashboard polls /sync-status while a sync runs and feeds the
/// rows through these to drive the "Updating… (done of total)" label.
library;

/// Institution `integration_type`s that actually sync. Manual / CSV / PDF
/// institutions are skipped server-side, so they're excluded from the progress
/// total (otherwise the count could never reach 100%). Must mirror the
/// backend's `SYNCABLE_TYPES` in `services/sync.rs` — those are exactly the
/// types the trigger pre-stamps `syncing`.
const Set<String> kSyncableInstitutionTypes = {
  'plaid',
  'coinbase',
  'coinbase_oauth',
  'bitso',
};

/// Number of institutions that will really sync — the denominator of the
/// "(done of total)" progress. Tolerant of nulls / malformed rows.
int syncableInstitutionCount(List<dynamic>? syncData) {
  if (syncData == null) return 0;
  return syncData
      .where(
        (i) =>
            i is Map &&
            kSyncableInstitutionTypes.contains(
              (i['integration_type'] ?? '').toString(),
            ),
      )
      .length;
}

/// How many syncable institutions are still `syncing`. Drives both the
/// progress count (done = total − syncing) and completion detection: the
/// manual-sync trigger pre-stamps every syncable institution `syncing`, the
/// detached backend task flips each to a terminal state (`synced`, `error`,
/// `reconnect_required`, …) as it finishes, and the dashboard polls this
/// until it reaches 0.
///
/// Unlike the old `last_synced_at`-based count, an *errored* institution
/// still counts as done here — it leaves `syncing` — so a single failing or
/// slow-then-timed-out institution can no longer wedge the progress at
/// "12/13". Scoped to syncable types because the engine also transiently
/// stamps manual rows `syncing` before flipping them to `manual`.
int syncingCount(List<dynamic>? syncData) {
  if (syncData == null) return 0;
  return syncData.where((i) {
    if (i is! Map) return false;
    if (!kSyncableInstitutionTypes.contains(
      (i['integration_type'] ?? '').toString(),
    )) {
      return false;
    }
    return (i['sync_status'] ?? '').toString() == 'syncing';
  }).length;
}
