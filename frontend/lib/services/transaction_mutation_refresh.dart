/// Post-mutation refresh orchestration for transaction edits.
///
/// Extracted from `dashboard_screen.dart` so the exact request set is
/// unit-testable without an `ApiService` (which imports `package:web` and
/// cannot load on the Dart test VM). The dashboard passes method tear-offs;
/// tests pass recording closures and assert precisely which reads run after
/// a mutation — and, just as importantly, which ones don't.
library;

import 'dart:async';

/// Hard cap the backend applies to the `limit` query param of
/// GET /dashboard/transactions — `q.limit.unwrap_or(50).clamp(1, 500)` in
/// `backend/src/api/dashboard.rs`. Bulk loaders (the filter cascade in
/// `TransactionsTab` and the depth-preserving refetches below) request at
/// most this many rows per call: asking for more is silently clamped
/// server-side, so keep this constant in sync with the backend clamp.
const int kTxBackendMaxPageSize = 500;

/// Page size for a transaction refetch that must re-cover what's already
/// on screen: at least one full page, deep enough to span every loaded row
/// (the user may have cascade-loaded pages for a client-side filter), but
/// never more than the backend will honor (see [kTxBackendMaxPageSize] —
/// a bigger ask would be clamped and silently truncate the list).
int txRefetchLimit({required int loadedCount, required int pageSize}) =>
    loadedCount.clamp(pageSize, kTxBackendMaxPageSize);

/// Overlay a fresh newest-first refetch onto the previously loaded list,
/// preserving loaded depth the (capped) refetch couldn't re-cover.
///
/// * Refetch came back SHORT of [requestedLimit] → the server ran out of
///   rows before hitting the limit, so [refetched] is the complete table:
///   return it as-is (this is what removes deleted rows).
/// * Refetch filled the limit → the window may have been truncated (either
///   by the backend cap or by rows added above it since the last load).
///   Keep the old contiguous tail: previous rows strictly below the
///   refetched window, found by walking up from the bottom of [previous]
///   until a row the refetch re-covered.
///
/// Known trade-off: a row mutated/deleted DEEPER than the refetch window
/// keeps its stale copy until the next explicit reload — acceptable next
/// to the old behavior (snap back to page 1, visibly reset the list, and
/// re-run the whole-history cascade after every edit).
List<dynamic> mergeRefetchedTransactions({
  required List<dynamic> previous,
  required List<dynamic> refetched,
  required int requestedLimit,
}) {
  if (refetched.length < requestedLimit || previous.isEmpty) return refetched;
  final refetchedIds = <String>{
    for (final t in refetched)
      if (t is Map && t['id'] != null) t['id'].toString(),
  };
  final tail = <dynamic>[];
  for (var i = previous.length - 1; i >= 0; i--) {
    final row = previous[i];
    final id = row is Map ? row['id']?.toString() : null;
    if (id != null && refetchedIds.contains(id)) break;
    tail.add(row);
  }
  if (tail.isEmpty) return refetched;
  return [...refetched, ...tail.reversed];
}

/// The reads a transaction mutation can actually affect, freshly fetched.
class TransactionMutationRefreshData {
  const TransactionMutationRefreshData({
    required this.transactions,
    required this.overview,
    required this.trends,
    this.fxTransfers,
  });

  final List<dynamic> transactions;
  final Map<String, dynamic> overview;
  final List<Map<String, dynamic>> trends;

  /// Null when the FX-transfer list wasn't requested (the mutation could
  /// not have touched transfer links, so the caller keeps its current list).
  final List<dynamic>? fxTransfers;
}

/// Fetch ONLY the reads a transaction mutation can actually change:
///
///  * the transaction list itself (which also feeds `BudgetsCard`),
///  * the dashboard overview (account balances / net worth / cash flow),
///  * the monthly trends behind the cash-flow cards,
///  * optionally the FX-transfer pairs, for mutations that link/unlink them.
///
/// Holdings / investments / crypto / FX-rate / stock-quote reads are
/// deliberately absent: a transaction edit cannot change them, and pulling
/// them used to make a one-row rename cost an external Yahoo re-price plus
/// a ~18-endpoint dashboard reload. Keep this set minimal — anything not
/// derived from transactions stays on the explicit-refresh path.
///
/// [transactionsLimit] is forwarded verbatim to [getTransactions] so the
/// refetch can preserve the caller's loaded depth (see [txRefetchLimit])
/// instead of always snapping back to the default first page. This changes
/// a query param only — the request SET stays at 3 (4 with FX transfers).
Future<TransactionMutationRefreshData> fetchAfterTransactionMutation({
  required Future<List<dynamic>> Function(int limit) getTransactions,
  required Future<Map<String, dynamic>> Function() getOverview,
  required Future<List<dynamic>> Function() getTrends,
  Future<List<dynamic>> Function()? getFxTransfers,
  int transactionsLimit = 50,
}) async {
  // Best-effort, like the equivalent fetch in `_loadAllData` — a transfer
  // listing hiccup shouldn't fail the whole post-mutation refresh. try/catch
  // rather than `catchError`: the fetcher's runtime future may be a narrower
  // subtype (e.g. `Future<Never>` from a closure that always throws), and
  // `catchError` requires its handler value to match that runtime type.
  Future<List<dynamic>> bestEffort(Future<List<dynamic>> Function() fetch) async {
    try {
      return await fetch();
    } catch (_) {
      return <dynamic>[];
    }
  }

  final results = await Future.wait<Object?>([
    getTransactions(transactionsLimit),
    getOverview(),
    getTrends(),
    if (getFxTransfers != null) bestEffort(getFxTransfers),
  ]);
  return TransactionMutationRefreshData(
    transactions: results[0] as List<dynamic>,
    overview: results[1] as Map<String, dynamic>,
    trends: (results[2] as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList(),
    fxTransfers: getFxTransfers == null ? null : results[3] as List<dynamic>,
  );
}
