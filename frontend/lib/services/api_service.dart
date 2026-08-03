import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;
import '../utils/app_locale.dart';
import '../utils/projection_seed.dart';
import 'api_platform.dart';
import 'auth_service.dart';
import 'response_cache.dart';
import 'tx_page.dart';

part 'api_service/auth.dart';
part 'api_service/dashboard.dart';
part 'api_service/holdings.dart';
part 'api_service/lending.dart';
part 'api_service/transactions.dart';

/// Pick the English or es-MX variant of a user-facing message based on the
/// app's active locale. Lives at top level so the (BuildContext-free) service
/// layer can localize thrown error messages without AppLocalizations.
String _t(String en, String es) =>
    localeNotifier.value?.languageCode == 'es' ? es : en;

/// Thrown when the server returns 401. The auth gate listens for this
/// indirectly via AuthService.handleUnauthorized().
class UnauthorizedException implements Exception {
  final String message;
  UnauthorizedException([this.message = 'Authentication required']);
  @override
  String toString() => message;
}

/// Thrown when a loan PATCH is rejected with 409 — the backend refuses
/// to change terms (principal / rate / interest type) after payments
/// have been reconciled, because a re-derived schedule would orphan the
/// already-paid rows. Carries the server's human-readable reason so the
/// edit dialog can surface it verbatim.
class LoanTermsLockedException implements Exception {
  final String message;
  LoanTermsLockedException(this.message);
  @override
  String toString() => message;
}

/// Thrown by [ApiService.restoreHolding] on a 404 — the soft-deleted row is
/// gone (24 h retention elapsed, purged by a re-add/import, or never existed),
/// so the deletion is permanent. Typed so the undo snackbar can tell "too
/// late" apart from a transient failure (contract C3-B/C3-E).
class HoldingRestoreGoneException implements Exception {
  final String message;
  HoldingRestoreGoneException(this.message);
  @override
  String toString() => message;
}

/// Thrown by [ApiService.linkDisbursement] on a 409 — the transaction the
/// caller tried to designate as a loan's disbursement already funds another
/// loan. Carries the server's human-readable reason.
class DisbursementConflictException implements Exception {
  final String message;
  DisbursementConflictException(this.message);
  @override
  String toString() => message;
}

/// Per-file progress tick from the streaming upload handler.
/// One file's live status within a multi-PDF import, for the per-file
/// checklist. [status] is one of:
///   'waiting'  — queued, not started (a later batch)
///   'parsing'  — in flight on the server right now
///   'ok'       — finished, parsed [count] transactions
///   'failed'   — finished with an error (skipped)
class ImportFileStatus {
  final String name;
  final String status;
  final int count;
  const ImportFileStatus(this.name, this.status, [this.count = 0]);

  ImportFileStatus copyWith({String? status, int? count}) =>
      ImportFileStatus(name, status ?? this.status, count ?? this.count);

  bool get isDone => status == 'ok' || status == 'failed';
}

/// Live import progress. [files] is the whole batch in submission order,
/// each carrying its own status, so the screen can render a per-file
/// checklist; [done]/[total] are the aggregate counts.
typedef ImportProgressCallback =
    void Function({
      required List<ImportFileStatus> files,
      required int done,
      required int total,
    });

/// Shared credentialed HTTP client. `withCredentials` is required for
/// the browser to send (and accept) the session cookie on cross-origin
/// XHRs in development, and is harmless in same-origin production.
final http.Client _defaultClient = createApiClient();

/// X-Requested-With sentinel. The backend's `require_csrf_header`
/// middleware rejects mutating requests without this header — a
/// classic CSRF attacker can't set custom headers from a malicious
/// origin without triggering a CORS preflight that our backend
/// refuses. The exact value doesn't matter (the middleware only
/// checks for non-empty), but we use "fetch" to match the convention
/// jQuery and friends introduced years ago.
const Map<String, String> _csrfHeader = {'X-Requested-With': 'fetch'};

/// The active HTTP client: [ApiService.debugHttpClientOverride] when a
/// test has installed one, otherwise the shared [_defaultClient].
/// Top-level (not a static) so the domain mixins in the part files
/// resolve it unqualified, exactly as the bodies did before the split.
http.Client get _client => ApiService.debugHttpClientOverride ?? _defaultClient;

/// The plumbing surface the domain mixins program against.
///
/// [ApiService]'s endpoints are split by domain into `part` files
/// (`api_service/*.dart`), one private mixin per domain, each `on` this
/// base and composed back into [ApiService]. Mixin members are ordinary
/// virtual instance members of [ApiService] — several widget tests fake
/// the service with `class _Fake extends ApiService { @override ... }`,
/// which is exactly why the split uses mixins and NOT extensions:
/// extension members dispatch statically and would silently bypass
/// those overrides.
///
/// Every member here is implemented by [ApiService] itself, alongside
/// the statics ([ApiService.debugHttpClientOverride],
/// [ApiService.clearDashboardCache]) that must stay on the public class.
abstract class _ApiServiceBase {
  String get _baseUrl;

  Map<String, String> _withCsrf(Map<String, String>? extra);

  Future<T> _cachedGet<T>(
    String key,
    Future<T> Function() fetch, {
    bool forceRefresh,
  });

  Future<http.Response> _get(Uri uri);

  Future<http.Response> _post(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  });

  Future<http.Response> _patch(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  });

  Future<http.Response> _put(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  });

  Future<http.Response> _delete(Uri uri);

  void _maybeUnauthorized(http.Response res);

  void _maybeUnauthorizedStreamed(http.StreamedResponse res);

  Exception _errorFromBody(http.Response res, {required String fallback});
}

class ApiService extends _ApiServiceBase
    with _AuthApi, _DashboardApi, _TxApi, _HoldingsApi, _LendingApi {
  @override
  String get _baseUrl => apiBaseUrl();

  String get baseUrl => _baseUrl;

  /// Test seam — when non-null, every request goes through this client
  /// instead of [_defaultClient], so the core plumbing (verb wrappers,
  /// CSRF header injection, 401 handling, `_errorFromBody`, cache
  /// interaction) can be unit-tested with a fake client and zero network
  /// I/O. Null in production (the same override-not-DI pattern as the
  /// screens' `fetch*Override` load seams); tests reset it in tearDown.
  @visibleForTesting
  static http.Client? debugHttpClientOverride;

  @override
  Map<String, String> _withCsrf(Map<String, String>? extra) {
    if (extra == null || extra.isEmpty) return _csrfHeader;
    return {..._csrfHeader, ...extra};
  }

  /// Short-TTL stale-while-revalidate cache for the heavy idempotent GET
  /// dashboard reads. Shared across every ApiService instance (the app
  /// constructs more than one) so a refresh from any caller benefits the
  /// rest. See `response_cache.dart` for the correctness model.
  ///
  /// WHY a cache: `dashboard_screen._loadAllData()` fires a ~15-endpoint
  /// `Future.wait` on EVERY reload (sub-screen return, realtime event).
  /// Transaction mutations now use the targeted
  /// `_refreshAfterTransactionMutation()` instead of a full reload, but
  /// the cache still collapses redundant reads inside the TTL window and
  /// de-dupes concurrent identical GETs into one network call.
  static final ResponseCache _cache = ResponseCache();

  /// Cache-key namespace prefix. `clearDashboardCache` / mutation
  /// invalidation operate on this whole family.
  static const String _dashKeyPrefix = 'dash:';

  /// Drop every cached dashboard read. Called by ANY mutation in this
  /// service — the simplest provably-safe invalidation strategy for a
  /// finance app: after a write we never want to serve a pre-write value.
  static void clearDashboardCache() => _cache.clear();

  /// Run a GET through the cache. [key] is namespaced under
  /// [_dashKeyPrefix]. [forceRefresh] bypasses any cached value and
  /// awaits a fresh fetch (used by realtime-triggered + explicit
  /// user-initiated refreshes so they never serve stale finance data).
  @override
  Future<T> _cachedGet<T>(
    String key,
    Future<T> Function() fetch, {
    bool forceRefresh = false,
  }) {
    return _cache.getOrFetch<T>(
      '$_dashKeyPrefix$key',
      fetch,
      forceRefresh: forceRefresh,
    );
  }

  @override
  Future<http.Response> _get(Uri uri) async {
    final res = await _client.get(uri);
    _maybeUnauthorized(res);
    return res;
  }

  @override
  Future<http.Response> _post(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final res = await _client.post(
      uri,
      body: body,
      headers: _withCsrf(headers),
    );
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

  @override
  Future<http.Response> _patch(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final res = await _client.patch(
      uri,
      body: body,
      headers: _withCsrf(headers),
    );
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

  @override
  Future<http.Response> _put(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final res = await _client.put(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

  @override
  Future<http.Response> _delete(Uri uri) async {
    final res = await _client.delete(uri, headers: _csrfHeader);
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

  /// Clear the dashboard cache after any non-error mutation. Centralising
  /// the invalidation in the verb wrappers (rather than sprinkling it
  /// through ~30 call sites) is what makes "every mutation invalidates"
  /// provable: a POST/PUT/PATCH/DELETE that succeeded cannot leave a
  /// pre-write value cached. We skip 4xx/5xx so a rejected request (which
  /// changed nothing) doesn't needlessly blow away warm cache entries.
  void _invalidateAfterMutation(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 400) {
      clearDashboardCache();
    }
  }

  @override
  void _maybeUnauthorized(http.Response res) {
    if (res.statusCode == 401) {
      AuthService.instance.handleUnauthorized();
      throw UnauthorizedException();
    }
  }

  /// Same contract as `_maybeUnauthorized` but for a
  /// `http.StreamedResponse` (used by uploadStatements, which can't
  /// materialise the full body into an `http.Response` without
  /// defeating the streaming progress events).
  @override
  void _maybeUnauthorizedStreamed(http.StreamedResponse res) {
    if (res.statusCode == 401) {
      AuthService.instance.handleUnauthorized();
      throw UnauthorizedException();
    }
  }

  @override
  Exception _errorFromBody(http.Response res, {required String fallback}) {
    try {
      final body = json.decode(res.body);
      if (body is Map && body['error'] is String) {
        return Exception(body['error'] as String);
      }
    } catch (_) {}
    return Exception('$fallback (${res.statusCode})');
  }
}
