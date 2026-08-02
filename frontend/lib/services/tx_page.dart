/// Typed result of one paged transaction fetch.
///
/// The backend list endpoints keep returning a bare JSON array body (so
/// shipped APKs that decode it directly keep working) and carry the total
/// matching-row count in an `X-Total-Count` response header instead. This
/// small model pairs the decoded rows with that header so callers can show
/// a stable "Showing X of N" denominator and derive an EXACT hasMore
/// (loaded < total) instead of the "full page ⇒ maybe more" heuristic.
///
/// Kept in its own file (not api_service.dart) per the house rule: typed
/// model over stringly access, without growing the ApiService god file.
library;

class TxPage {
  const TxPage({required this.rows, this.totalCount});

  /// Decoded response body — the same `List<dynamic>` the endpoints have
  /// always returned.
  final List<dynamic> rows;

  /// Server-side total matching rows across ALL pages, from
  /// `X-Total-Count`. Null when the header is absent (older backend, an
  /// empty result, or an unparsable value) — callers must fall back to
  /// their pre-header heuristics.
  final int? totalCount;

  /// Parse the total from a response header map. `package:http` lowercases
  /// header keys, so only the lowercase form is looked up. Absent or
  /// garbage values → null (treated exactly like an older backend).
  static int? totalFromHeaders(Map<String, String> headers) =>
      int.tryParse(headers['x-total-count'] ?? '');
}
