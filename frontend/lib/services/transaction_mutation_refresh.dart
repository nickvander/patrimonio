/// Post-mutation refresh orchestration for transaction edits.
///
/// Extracted from `dashboard_screen.dart` so the exact request set is
/// unit-testable without an `ApiService` (which imports `package:web` and
/// cannot load on the Dart test VM). The dashboard passes method tear-offs;
/// tests pass recording closures and assert precisely which reads run after
/// a mutation — and, just as importantly, which ones don't.
library;

import 'dart:async';

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
Future<TransactionMutationRefreshData> fetchAfterTransactionMutation({
  required Future<List<dynamic>> Function() getTransactions,
  required Future<Map<String, dynamic>> Function() getOverview,
  required Future<List<dynamic>> Function() getTrends,
  Future<List<dynamic>> Function()? getFxTransfers,
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
    getTransactions(),
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
