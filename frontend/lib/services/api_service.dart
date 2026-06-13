import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import '../utils/app_locale.dart';
import 'api_platform.dart';
import 'auth_service.dart';
import 'response_cache.dart';

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
typedef ImportProgressCallback = void Function({
  required List<ImportFileStatus> files,
  required int done,
  required int total,
});

class ApiService {
  String get _baseUrl => apiBaseUrl();

  String get baseUrl => _baseUrl;

  /// Shared credentialed HTTP client. `withCredentials` is required for
  /// the browser to send (and accept) the session cookie on cross-origin
  /// XHRs in development, and is harmless in same-origin production.
  static final http.Client _client = createApiClient();

  /// X-Requested-With sentinel. The backend's `require_csrf_header`
  /// middleware rejects mutating requests without this header — a
  /// classic CSRF attacker can't set custom headers from a malicious
  /// origin without triggering a CORS preflight that our backend
  /// refuses. The exact value doesn't matter (the middleware only
  /// checks for non-empty), but we use "fetch" to match the convention
  /// jQuery and friends introduced years ago.
  static const Map<String, String> _csrfHeader = {
    'X-Requested-With': 'fetch',
  };

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

  Future<http.Response> _get(Uri uri) async {
    final res = await _client.get(uri);
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _post(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.post(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

  Future<http.Response> _patch(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.patch(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

  Future<http.Response> _put(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.put(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    _invalidateAfterMutation(res);
    return res;
  }

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
  void _maybeUnauthorizedStreamed(http.StreamedResponse res) {
    if (res.statusCode == 401) {
      AuthService.instance.handleUnauthorized();
      throw UnauthorizedException();
    }
  }

  // ----- auth -----

  Future<Map<String, dynamic>> authStatus() async {
    final res = await _client.get(Uri.parse('$_baseUrl/auth/status'));
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception(_t('Failed to load auth status (${res.statusCode})',
        'No se pudo cargar el estado de autenticación (${res.statusCode})'));
  }

  Future<LoginOutcome> login(String username, String password) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'username': username, 'password': password}),
    );
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (body['requires_totp'] == true) {
        return const LoginOutcome.needsTotp();
      }
      return LoginOutcome.complete(AuthUser.fromJson(body));
    }
    throw _errorFromBody(res,
        fallback: _t('Login failed', 'No se pudo iniciar sesión'));
  }

  Future<AuthUser> verifyTotp(String code) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/totp/verify'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'code': code}),
    );
    if (res.statusCode == 200) {
      return AuthUser.fromJson(json.decode(res.body) as Map<String, dynamic>);
    }
    throw _errorFromBody(res,
        fallback: _t('TOTP verification failed',
            'No se pudo verificar el código TOTP'));
  }

  Future<BootstrapOutcome> bootstrap({
    required String username,
    String? email,
    required String password,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/bootstrap'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'username': username,
        'email': email,
        'password': password,
      }),
    );
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      final codes = ((body['recovery_codes'] as List?) ?? const [])
          .cast<String>();
      return BootstrapOutcome(
        AuthUser.fromJson(body['user'] as Map<String, dynamic>),
        codes,
      );
    }
    throw _errorFromBody(res,
        fallback: _t('Bootstrap failed', 'No se pudo crear la cuenta inicial'));
  }

  /// Redeem an invite token + create a new user account. Same shape
   /// as bootstrap on success: the new user is signed in, recovery
   /// codes are returned once.
  Future<BootstrapOutcome> register({
    required String token,
    required String username,
    String? email,
    required String password,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'token': token,
        'username': username,
        'email': email,
        'password': password,
      }),
    );
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      final codes = ((body['recovery_codes'] as List?) ?? const [])
          .cast<String>();
      return BootstrapOutcome(
        AuthUser.fromJson(body['user'] as Map<String, dynamic>),
        codes,
      );
    }
    throw _errorFromBody(res,
        fallback: _t('Registration failed', 'No se pudo completar el registro'));
  }

  /// Mint a new invite token. Authenticated. Returns the plaintext
  /// token + a shareable URL (`<frontend>/?invite=<token>`) + the
  /// absolute expiry time in ISO 8601.
  Future<InviteMint> createInvite({
    int? expiresInHours,
    String? note,
    String? role,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/invites'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        if (expiresInHours != null) 'expires_in_hours': expiresInHours,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        // 'owner' or 'read_only'. Omitted → backend defaults to 'owner',
        // preserving the historical invite contract.
        if (role != null) 'role': role,
      }),
    );
    _maybeUnauthorized(res);
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return InviteMint(
        id: body['id'] as String,
        token: body['token'] as String,
        url: body['url'] as String,
        expiresAt: DateTime.parse(body['expires_at'] as String),
      );
    }
    throw _errorFromBody(res,
        fallback: _t('Failed to mint invite', 'No se pudo generar la invitación'));
  }

  Future<List<InviteSummary>> listInvites() async {
    final res = await _get(Uri.parse('$_baseUrl/auth/invites'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as List<dynamic>;
      return body
          .cast<Map<String, dynamic>>()
          .map(InviteSummary.fromJson)
          .toList();
    }
    throw _errorFromBody(res,
        fallback: _t('Failed to list invites',
            'No se pudieron cargar las invitaciones'));
  }

  Future<void> revokeInvite(String id) async {
    final res = await _client.delete(
      Uri.parse('$_baseUrl/auth/invites/$id'),
      headers: _csrfHeader,
    );
    _maybeUnauthorized(res);
    if (res.statusCode != 204) {
      throw _errorFromBody(res,
          fallback: _t('Failed to revoke invite',
              'No se pudo revocar la invitación'));
    }
  }

  Future<void> recover({
    required String username,
    required String code,
    required String newPassword,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/recover'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'username': username,
        'code': code,
        'new_password': newPassword,
      }),
    );
    if (res.statusCode != 204) {
      throw _errorFromBody(res,
          fallback: _t('Password reset failed',
              'No se pudo restablecer la contraseña'));
    }
  }

  Future<List<String>> regenerateRecoveryCodes() async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/recovery-codes/regenerate'),
      headers: _csrfHeader,
    );
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return ((body['codes'] as List?) ?? const []).cast<String>();
    }
    _maybeUnauthorized(res);
    throw _errorFromBody(res,
        fallback: _t('Regenerate failed',
            'No se pudieron regenerar los códigos'));
  }

  Future<int> recoveryCodesCount() async {
    final res = await _get(Uri.parse('$_baseUrl/auth/recovery-codes/count'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['unused'] as num).toInt();
    }
    throw _errorFromBody(res,
        fallback: _t('Count failed',
            'No se pudo obtener el conteo de códigos'));
  }

  Future<({String secretBase32, String provisioningUri})> beginTotpEnroll() async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/totp/enroll'),
      headers: _csrfHeader,
    );
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (
        secretBase32: body['secret_base32'] as String,
        provisioningUri: body['provisioning_uri'] as String,
      );
    }
    _maybeUnauthorized(res);
    throw _errorFromBody(res,
        fallback: _t('TOTP enroll failed',
            'No se pudo iniciar el registro de TOTP'));
  }

  Future<void> confirmTotpEnroll(String code) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/totp/confirm'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'code': code}),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res,
          fallback: _t('TOTP confirm failed',
              'No se pudo confirmar el TOTP'));
    }
  }

  Future<void> disableTotp(String currentPassword) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/totp/disable'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'current_password': currentPassword}),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res,
          fallback: _t('Disable TOTP failed',
              'No se pudo desactivar el TOTP'));
    }
  }

  /// One row of the Active Sessions list. Mirrors the
  /// ActiveSessionView Rust struct.
  Future<List<ActiveSession>> listSessions() async {
    final res = await _get(Uri.parse('$_baseUrl/auth/sessions'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as List<dynamic>;
      return body
          .map((e) => ActiveSession.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw _errorFromBody(res,
        fallback: _t('Failed to load sessions',
            'No se pudieron cargar las sesiones'));
  }

  Future<void> revokeSession(String sessionId) async {
    final res = await _delete(
      Uri.parse('$_baseUrl/auth/sessions/$sessionId'),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res,
          fallback: _t('Failed to revoke session',
              'No se pudo revocar la sesión'));
    }
  }

  /// Returns the number of OTHER sessions that were revoked. The
  /// current cookie stays alive so the page keeps working.
  Future<int> revokeOtherSessions() async {
    final res = await _post(Uri.parse('$_baseUrl/auth/sessions/revoke-others'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['revoked'] as num).toInt();
    }
    throw _errorFromBody(res,
        fallback: _t('Failed to revoke other sessions',
            'No se pudieron revocar las demás sesiones'));
  }

  Future<void> logout() async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/logout'),
      headers: _csrfHeader,
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw _errorFromBody(res,
          fallback: _t('Logout failed', 'No se pudo cerrar sesión'));
    }
  }

  Future<void> changePassword(String currentPassword, String newPassword) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/change-password'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'current_password': currentPassword,
        'new_password': newPassword,
      }),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res,
          fallback: _t('Password change failed',
              'No se pudo cambiar la contraseña'));
    }
  }

  Exception _errorFromBody(http.Response res, {required String fallback}) {
    try {
      final body = json.decode(res.body);
      if (body is Map && body['error'] is String) {
        return Exception(body['error'] as String);
      }
    } catch (_) {}
    return Exception('$fallback (${res.statusCode})');
  }

  // ----- existing endpoints (now credentialed) -----

  Future<Map<String, dynamic>> getDashboardOverview({
    bool forceRefresh = false,
  }) {
    return _cachedGet('overview', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/overview'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load dashboard overview',
          'No se pudo cargar el resumen del panel'));
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getNetWorthHistory({bool forceRefresh = false}) {
    return _cachedGet('net-worth-history', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/net-worth-history'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load net worth history',
          'No se pudo cargar el historial de patrimonio neto'));
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getAllocationData({bool forceRefresh = false}) {
    return _cachedGet('allocation', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/allocation'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load allocation data',
          'No se pudieron cargar los datos de distribución'));
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getTrendData({bool forceRefresh = false}) {
    return _cachedGet('trends', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/trends'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load trend data',
          'No se pudieron cargar los datos de tendencias'));
    }, forceRefresh: forceRefresh);
  }

  /// Per-category spending over the trailing [months] months. Returns the
  /// `{months: [...], categories: [...]}` shape from the backend, with the
  /// top categories kept verbatim and the rest folded into "OTHER".
  Future<Map<String, dynamic>> getSpendingByCategory({
    int months = 6,
    int top = 6,
    bool forceRefresh = false,
  }) {
    return _cachedGet('spending-by-category-$months-$top', () async {
      final response = await _get(Uri.parse(
          '$_baseUrl/dashboard/spending-by-category?months=$months&top=$top'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load spending by category',
          'No se pudo cargar el gasto por categoría'));
    }, forceRefresh: forceRefresh);
  }

  /// Per-category month-over-month-vs-trailing-average spend deltas. Returns
  /// the `{recent_month, lookback, categories:[{user_category, category_detailed,
  /// category, recent, previous_avg, trailing_avg}]}` shape. Powers the
  /// spending-insight notifications and the budget auto-suggestions.
  Future<Map<String, dynamic>> getSpendingInsights({
    int lookback = 3,
    bool forceRefresh = false,
  }) {
    return _cachedGet('spending-insights-$lookback', () async {
      final response = await _get(Uri.parse(
          '$_baseUrl/dashboard/spending-insights?lookback=$lookback'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load spending insights',
          'No se pudieron cargar los análisis de gasto'));
    }, forceRefresh: forceRefresh);
  }

  /// Investment portfolio value over time: `[{date, value_usd}]` (USD), from
  /// balance snapshots of accounts that hold investments. Powers the
  /// performance chart. Empty list on error so the card simply hides.
  Future<List<dynamic>> getPortfolioValueHistory({bool forceRefresh = false}) {
    return _cachedGet('portfolio-value-history', () async {
      final response =
          await _get(Uri.parse('$_baseUrl/dashboard/portfolio-value-history'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load portfolio value history',
          'No se pudo cargar el historial de valor del portafolio'));
    }, forceRefresh: forceRefresh);
  }

  /// S&P 500 daily closes (for the net-worth-vs-market overlay). [from] is an
  /// ISO date string. Returns the `{symbol, points:[{date,close}]}` shape;
  /// empty list on any error so the card simply hides.
  Future<Map<String, dynamic>?> getBenchmarkSeries({String? from}) async {
    try {
      final q = from != null ? '?from=$from' : '';
      final r = await _get(Uri.parse('$_baseUrl/dashboard/benchmark$q'));
      if (r.statusCode == 200) {
        final decoded = json.decode(r.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {
      // best-effort; card hides
    }
    return null;
  }

  /// Contribution-weighted "you vs S&P 500" over tracked holding lots.
  /// Returns {invested_usd, your_value_usd, benchmark_value_usd, lot_count}.
  Future<Map<String, dynamic>?> getBenchmarkComparison() async {
    try {
      final r = await _get(
          Uri.parse('$_baseUrl/dashboard/benchmark-comparison'));
      if (r.statusCode == 200) {
        final decoded = json.decode(r.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {}
    return null;
  }

  /// True time-weighted return: daily growth index of the portfolio (cashflows
  /// divided out) + the S&P 500 over the same dates, plus `coverage_pct`.
  /// Returns the `{start_date, end_date, coverage_pct, your_twr, sp_twr,
  /// points:[{date, twr, sp}], ...}` shape; null on any error so the card
  /// falls back to the dollar-value line.
  Future<Map<String, dynamic>?> getPortfolioTwr() async {
    try {
      final r = await _get(Uri.parse('$_baseUrl/dashboard/portfolio-twr'));
      if (r.statusCode == 200) {
        final decoded = json.decode(r.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {}
    return null;
  }

  /// Emergency-fund runway: liquid cash / trailing monthly spend (USD).
  Future<Map<String, dynamic>> getEmergencyFund({bool forceRefresh = false}) {
    return _cachedGet('emergency-fund', () async {
      final r = await _get(Uri.parse('$_baseUrl/dashboard/emergency-fund'));
      if (r.statusCode == 200) {
        return json.decode(r.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load emergency fund',
          'No se pudo cargar el fondo de emergencia'));
    }, forceRefresh: forceRefresh);
  }

  /// Monthly closing balances for one account (native currency), derived from
  /// the persisted statement `balance_after`. Empty for Plaid-only accounts.
  Future<List<dynamic>> getAccountBalanceHistory(String accountId) async {
    try {
      final response = await _get(Uri.parse(
          '$_baseUrl/dashboard/account-balance-history?account_id=$accountId'));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        return decoded is List ? decoded : const [];
      }
    } catch (_) {
      // Best-effort; the chart simply won't render.
    }
    return const [];
  }

  /// Realized capital gains/losses from lot disposals. Optional [year]
  /// narrows the disposal list; the summary + by-year always cover history.
  Future<Map<String, dynamic>> getRealizedGains({
    int? year,
    bool forceRefresh = false,
  }) {
    return _cachedGet('realized-gains-${year ?? 'all'}', () async {
      final q = year != null ? '?year=$year' : '';
      final response =
          await _get(Uri.parse('$_baseUrl/dashboard/realized-gains$q'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load realized gains',
          'No se pudieron cargar las ganancias realizadas'));
    }, forceRefresh: forceRefresh);
  }

  Future<Map<String, dynamic>> getHoldings({bool forceRefresh = false}) {
    return _cachedGet('holdings', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/holdings'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load holdings',
          'No se pudieron cargar las posiciones'));
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getCreditUtilization({bool forceRefresh = false}) {
    return _cachedGet('credit-utilization', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/credit-utilization'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load credit utilization',
          'No se pudo cargar el uso de crédito'));
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getSyncStatus({bool forceRefresh = false}) {
    return _cachedGet('sync-status', () async {
      final response = await _get(Uri.parse('$_baseUrl/dashboard/sync-status'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load sync status',
          'No se pudo cargar el estado de sincronización'));
    }, forceRefresh: forceRefresh);
  }

  /// Summary of "what changed since your previous login" — used by the
  /// dismissible Overview banner. Returns null when the user has no
  /// previous login (first session ever), so the caller can skip rendering.
  Future<Map<String, dynamic>?> getSinceLastLogin({
    bool forceRefresh = false,
  }) {
    return _cachedGet('since-last-login', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/since-last-login'),
      );
      if (response.statusCode != 200) return null;
      final body = json.decode(response.body) as Map<String, dynamic>;
      // Backend signals "no previous login" by omitting `previous_login_at`.
      if (body['previous_login_at'] == null) return null;
      return body;
    }, forceRefresh: forceRefresh);
  }

  /// List every dismissed subscription merchant. Returned shape:
  /// `[{merchant_key, ignored_at}, ...]`.
  Future<List<dynamic>> getIgnoredSubscriptions({bool forceRefresh = false}) {
    return _cachedGet('subscriptions/ignored', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/subscriptions/ignored'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load ignored subscriptions',
          'No se pudieron cargar las suscripciones ignoradas'));
    }, forceRefresh: forceRefresh);
  }

  /// Un-ignore: lets the detector resurface this merchant on the
  /// next run. Idempotent — 204 either way.
  Future<void> unignoreSubscription(String merchantKey) async {
    final response = await _delete(
      Uri.parse(
        '$_baseUrl/dashboard/subscriptions/ignored/${Uri.encodeComponent(merchantKey)}',
      ),
    );
    if (response.statusCode != 204) {
      throw Exception(_t('Failed to un-ignore subscription',
          'No se pudo dejar de ignorar la suscripción'));
    }
  }

  /// Mark a detected subscription cluster as "not actually a
  /// subscription" — the detector skips this merchant on future runs.
  Future<void> ignoreSubscription(String merchant) async {
    final response = await _post(
      Uri.parse('$_baseUrl/dashboard/subscriptions/ignore'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'merchant': merchant}),
    );
    if (response.statusCode != 204) {
      throw Exception(_t('Failed to dismiss subscription',
          'No se pudo descartar la suscripción'));
    }
  }

  /// Detected recurring outflows (subscriptions, bills, gym, etc.).
  /// See `dashboard.rs::detected_subscriptions` for the heuristic.
  Future<List<dynamic>> getSubscriptions({bool forceRefresh = false}) {
    return _cachedGet('subscriptions', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/subscriptions'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load subscriptions',
          'No se pudieron cargar las suscripciones'));
    }, forceRefresh: forceRefresh);
  }

  /// Linked cross-currency cash transfers. Each row pairs a USD-out
  /// with an MXN-in (or reverse) plus the implied FX rate Wise/Remitly
  /// gave the user.
  Future<List<dynamic>> getFxTransfers({bool forceRefresh = false}) {
    return _cachedGet('fx-transfers', () async {
      final response = await _get(
        Uri.parse('$_baseUrl/dashboard/fx-transfers'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load FX transfers',
          'No se pudieron cargar las transferencias de divisas'));
    }, forceRefresh: forceRefresh);
  }

  /// Run a detection pass on the server. Returns
  /// `{checked, inserted}` so the UI can say "added N new links".
  Future<Map<String, dynamic>> detectFxTransfers() async {
    final response = await _post(
      Uri.parse('$_baseUrl/dashboard/fx-transfers'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(_t('FX detection failed',
        'No se pudo detectar transferencias de divisas'));
  }

  Future<void> confirmFxTransfer(String id) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/$id'),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Confirm failed (${response.statusCode})',
          'No se pudo confirmar (${response.statusCode})'));
    }
  }

  Future<void> unlinkFxTransfer(String id) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/$id'),
    );
    if (response.statusCode != 204) {
      throw Exception(_t('Unlink failed (${response.statusCode})',
          'No se pudo desvincular (${response.statusCode})'));
    }
  }

  /// List FX pairs the user has permanently dismissed. Each row is
  /// `{ id, source_label, dest_label, source_date, dest_date,
  /// source_amount, source_currency, dest_amount, dest_currency,
  /// dismissed_at }`. Used by the Hidden Items screen.
  Future<List<dynamic>> getDismissedFxPairs() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/dismissed'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load dismissed FX pairs',
        'No se pudieron cargar los pares de divisas descartados'));
  }

  /// Restore a dismissed FX pair so the detector can re-propose it
  /// on the next run. Idempotent — 204 even if already gone.
  Future<void> restoreDismissedFxPair(String dismissalId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/dismissed/$dismissalId'),
    );
    if (response.statusCode != 204) {
      throw Exception(_t('Restore failed (${response.statusCode})',
          'No se pudo restaurar (${response.statusCode})'));
    }
  }

  Future<Map<String, dynamic>> getSetupStatus() async {
    // Setup status is a public endpoint — used by the login screen — so
    // we still send credentials but the server does not require them.
    final response = await _client.get(Uri.parse('$_baseUrl/setup/status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load setup status',
        'No se pudo cargar el estado de configuración'));
  }

  Future<Map<String, dynamic>> getExchangeRate(
    String base,
    String target, {
    bool force = false,
  }) async {
    final query = force ? '?force=true' : '';
    final response = await _get(
      Uri.parse('$_baseUrl/fx/latest/$base/$target$query'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load exchange rate',
        'No se pudo cargar el tipo de cambio'));
  }

  Future<List<dynamic>> getTransactions({int limit = 50, int offset = 0}) async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/transactions?limit=$limit&offset=$offset'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load transactions',
        'No se pudieron cargar los movimientos'));
  }

  /// One newest-first page of a single account's transactions. With no
  /// [limit] the backend keeps its legacy single-shot behavior (up to
  /// 1,000 rows); an explicit limit is clamped server-side to ≤500 per
  /// request (same cap as `/dashboard/transactions`, see
  /// [kTxBackendMaxPageSize] in transaction_mutation_refresh.dart).
  Future<List<dynamic>> getAccountTransactions(
    String accountId, {
    int? limit,
    int? offset,
  }) async {
    final params = <String>[
      if (limit != null) 'limit=$limit',
      if (offset != null) 'offset=$offset',
    ];
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    final response = await _get(
      Uri.parse('$_baseUrl/accounts/$accountId/transactions$query'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load account transactions',
        'No se pudieron cargar los movimientos de la cuenta'));
  }

  Future<void> syncInstitutions() async {
    final response = await _post(Uri.parse('$_baseUrl/institutions/sync'));
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to sync institutions',
          'No se pudieron sincronizar las instituciones'));
    }
  }

  Future<Map<String, dynamic>> getReconnectToken(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/reconnect-token/$institutionId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to retrieve reconnect token',
        'No se pudo obtener el token de reconexión'));
  }

  /// Swap a Plaid public token (from a completed Link session) for a stored
  /// access token, creating the institution. Used by the OAuth-redirect resume
  /// path; the in-tab connect flow calls the same endpoint directly.
  Future<void> exchangePublicToken(String publicToken, String institutionName,
      {String institutionType = 'banking'}) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/exchange-token'),
      body: json.encode({
        'public_token': publicToken,
        'institution_name': institutionName,
        'institution_type': institutionType,
      }),
      headers: const {'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to exchange public token',
          'No se pudo intercambiar el token público'));
    }
  }

  Future<void> deleteInstitution(String institutionId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/institutions/$institutionId'),
    );
    if (response.statusCode != 204) {
      throw Exception(_t('Failed to delete institution',
          'No se pudo eliminar la institución'));
    }
  }

  /// Multi-file batch wrapper around /imports/upload. The server
  /// returns one `ImportResponse` JSON object per request (the
  /// shape `{status, message, transactions_count, transactions}`).
  ///
  /// Per-file progress: when `onProgress` is supplied, the client
  /// generates a UUID and sends it as the `X-Upload-Job-Id` header.
  /// While the upload POST is in flight, a parallel polling loop
  /// hits `GET /imports/progress/{job_id}` every 250 ms; each
  /// snapshot fires `onProgress`. The progress channel is fully
  /// independent of the upload connection — that avoids the
  /// ERR_CONNECTION_RESET the earlier bidirectional-stream design
  /// caused (response chunks flushing while the upload body was
  /// still arriving made Chromium abort).
  Future<Map<String, dynamic>> uploadStatements(
    List<PlatformFile> files, {
    String? password,
    ImportProgressCallback? onProgress,
    int? maxBatchBytes,
  }) async {
    final usable = files.where((f) => f.bytes != null).toList();
    if (usable.isEmpty) {
      throw Exception(_t('No files to upload',
          'No hay archivos para subir'));
    }

    // Split into batches that each stay under the server's body limit,
    // so a big multi-year drop doesn't bounce off the 100 MB cap — the
    // user no longer has to split by hand. Null = one batch (callers
    // that don't care about the cap, e.g. a single small CSV).
    final batches =
        maxBatchBytes == null ? [usable] : _packIntoBatches(usable, maxBatchBytes);

    // The full checklist, in submission order, seeded as 'waiting'.
    final order = usable.map((f) => f.name).toList();
    final status = <String, ImportFileStatus>{
      for (final f in usable) f.name: ImportFileStatus(f.name, 'waiting'),
    };
    void emit() {
      if (onProgress == null) return;
      final list = [for (final n in order) status[n]!];
      onProgress(
        files: list,
        done: list.where((s) => s.isDone).length,
        total: list.length,
      );
    }

    emit(); // initial all-waiting render

    final merged = <dynamic>[];
    // Account metadata (CLABE, holder, suggested name + balance) from the
    // newest statement across all batches — the batch wrapper must carry this
    // through or the preview can't pre-fill / match an account.
    Map<String, dynamic>? accountInfo;
    var sawSuccess = false;
    for (final batch in batches) {
      // Files in the in-flight batch all start at once on the server's
      // blocking pool — show them as 'parsing'; later batches stay
      // 'waiting'.
      for (final f in batch) {
        final s = status[f.name];
        if (s != null && !s.isDone) {
          status[f.name] = s.copyWith(status: 'parsing');
        }
      }
      emit();

      final resp = await _uploadOneBatch(
        batch,
        password,
        onProgress == null
            ? null
            : (completed) {
                for (final c in completed) {
                  if (status.containsKey(c.name)) status[c.name] = c;
                }
                emit();
              },
      );

      // One password covers the whole set — surface immediately so the
      // user re-enters it and retries everything (mirrors the old
      // single-request semantics).
      if (resp['status']?.toString() == 'password_required') {
        return resp;
      }
      final txs = resp['transactions'];
      if (txs is List) {
        merged.addAll(txs);
        if (txs.isNotEmpty) sawSuccess = true;
      }
      final ai = resp['account_info'];
      if (ai is Map<String, dynamic>) {
        final curEnd = accountInfo?['period_end']?.toString();
        final newEnd = ai['period_end']?.toString();
        if (accountInfo == null ||
            (newEnd != null &&
                (curEnd == null || newEnd.compareTo(curEnd) > 0))) {
          accountInfo = ai;
        }
      }
    }

    // Resolve anything the server never reported (older API without the
    // per-file channel, or a missed final poll) so no row hangs on
    // 'parsing'.
    for (final n in order) {
      final s = status[n]!;
      if (!s.isDone) status[n] = s.copyWith(status: 'ok');
    }
    emit();

    final fileCount = usable.length;
    final plural = fileCount == 1 ? '' : 's';
    final String message;
    if (sawSuccess) {
      message = _t(
        'Parsed ${merged.length} transactions from $fileCount file$plural.',
        'Se procesaron ${merged.length} transacciones de $fileCount '
            'archivo$plural.',
      );
    } else {
      // Nothing parsed. Summarise concisely from the checklist (the
      // backend's all-failed message is a long per-file dump) and point
      // at the likely cause.
      final failed =
          status.values.where((s) => s.status == 'failed').length;
      if (failed > 0) {
        message = _t(
          'No transactions found. $failed of $fileCount file$plural '
              "couldn't be read — make sure each is a Nu, Banamex, or "
              'CetesDirecto statement (PDF or CSV).',
          'No se encontraron transacciones. No se pudieron leer $failed de '
              '$fileCount archivo$plural: asegúrate de que cada uno sea un '
              'estado de cuenta de Nu, Banamex o CetesDirecto (PDF o CSV).',
        );
      } else {
        message = _t(
          'No transactions found in the selected file$plural.',
          'No se encontraron transacciones en '
              '${fileCount == 1 ? 'el archivo seleccionado' : 'los archivos seleccionados'}.',
        );
      }
    }
    return {
      'status': sawSuccess ? 'success' : 'error',
      'message': message,
      'transactions_count': merged.length,
      'transactions': merged,
      if (accountInfo != null) 'account_info': accountInfo,
    };
  }

  /// Greedy bin-pack: walk the files in order, starting a new batch
  /// whenever adding the next would push the running total over
  /// [maxBytes]. A single file larger than [maxBytes] still lands alone
  /// in its own batch (the caller pre-screens for files over the hard
  /// server cap).
  List<List<PlatformFile>> _packIntoBatches(
      List<PlatformFile> files, int maxBytes) {
    final batches = <List<PlatformFile>>[];
    var current = <PlatformFile>[];
    var currentBytes = 0;
    for (final f in files) {
      final sz = f.size;
      if (current.isNotEmpty && currentBytes + sz > maxBytes) {
        batches.add(current);
        current = <PlatformFile>[];
        currentBytes = 0;
      }
      current.add(f);
      currentBytes += sz;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Upload ONE batch (single multipart POST) and return its
  /// `ImportResponse` JSON. When [onFiles] is supplied, a job-id is sent
  /// and a parallel poller reports each file's completion as it parses;
  /// a final reconcile fetch guarantees the terminal per-file state is
  /// delivered even if the background poller exited first.
  Future<Map<String, dynamic>> _uploadOneBatch(
    List<PlatformFile> files,
    String? password,
    void Function(List<ImportFileStatus> completed)? onFiles,
  ) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/imports/upload'),
    );
    // Mirror the protected router's CSRF guard. The multipart helper
    // bypasses our _post wrapper, so attach the header by hand.
    request.headers['X-Requested-With'] = 'fetch';

    final String? jobId = onFiles != null ? _generateJobId() : null;
    if (jobId != null) {
      request.headers['X-Upload-Job-Id'] = jobId;
    }

    for (final f in files) {
      if (f.bytes == null) continue;
      request.files.add(
        http.MultipartFile.fromBytes('file', f.bytes!, filename: f.name),
      );
    }
    if (password != null && password.isNotEmpty) {
      request.fields['password'] = password;
    }

    bool uploadComplete = false;
    Future<void>? pollerFuture;
    if (jobId != null && onFiles != null) {
      pollerFuture = _pollUploadProgress(jobId, onFiles, () => uploadComplete);
    }

    try {
      // 600s (10 min) timeout. The backend parallelises PDF parsing
      // across the blocking pool, but each file is still CPU-bound for
      // several seconds (qpdf decrypt + lopdf extract + table recovery).
      final streamedResponse = await _client.send(request).timeout(
            const Duration(seconds: 600),
          );
      _maybeUnauthorizedStreamed(streamedResponse);

      final response = await http.Response.fromStream(streamedResponse);
      // The import endpoint returns an ImportResponse JSON on 200
      // (success / password_required) AND on 422 (every file failed or
      // yielded 0 transactions). Treat both as a valid result so an
      // all-skipped batch surfaces its per-file outcome + message instead
      // of throwing — only genuine transport/size failures below become
      // exceptions.
      if (response.statusCode == 200 || response.statusCode == 422) {
        Map<String, dynamic>? decoded;
        try {
          final body = json.decode(response.body);
          if (body is Map<String, dynamic> && body.containsKey('status')) {
            decoded = body;
          }
        } catch (_) {
          // Non-JSON body (e.g. a multipart read error) — fall through to
          // the size/transport handling below.
        }
        if (decoded != null) {
          // Multipart upload bypasses the _post/_patch verb wrappers, so
          // the central post-mutation invalidation doesn't fire here —
          // clear by hand, but only when something was actually imported.
          if (decoded['status'] == 'success') clearDashboardCache();
          // Final reconcile: the background poller may have exited before
          // the terminal snapshot, so fetch it once to ensure every
          // file's final state reaches the checklist.
          if (jobId != null && onFiles != null) {
            await _fetchFinalProgress(jobId, onFiles);
          }
          return decoded;
        }
      }
      // Payload-too-large surfaces as a real 413 OR (more often through
      // the axum multipart stack) as a truncated body that makes parsing
      // fail with 4xx/5xx. With auto-batching this should be rare, but
      // keep the specific hint for the no-batch path.
      if (response.statusCode == 413 ||
          response.body.contains('failed to read stream') ||
          response.body.contains('body limit exceeded')) {
        final totalMb = files
                .map((f) => (f.bytes?.length ?? 0))
                .fold<int>(0, (a, b) => a + b) /
            (1024 * 1024);
        throw Exception(_t(
          'Upload too large (${totalMb.toStringAsFixed(1)} MB across '
          '${files.length} file${files.length == 1 ? '' : 's'}). '
          'Try splitting into smaller batches.',
          'La carga es demasiado grande (${totalMb.toStringAsFixed(1)} MB en '
          '${files.length} archivo${files.length == 1 ? '' : 's'}). '
          'Intenta dividirla en lotes más pequeños.',
        ));
      }
      throw Exception(_t(
          'Server returned ${response.statusCode}: ${response.body}',
          'El servidor respondió ${response.statusCode}: ${response.body}'));
    } on TimeoutException catch (_) {
      throw Exception(_t(
        'Upload timed out after 10 minutes. '
        'Try splitting the batch into smaller groups (e.g. 6 PDFs at a time) '
        'or check that the API container is still running.',
        'La carga agotó el tiempo de espera tras 10 minutos. '
        'Intenta dividir el lote en grupos más pequeños (p. ej. 6 PDF a la vez) '
        'o verifica que el contenedor de la API siga en ejecución.',
      ));
    } on http.ClientException catch (e) {
      throw Exception(_t(
        'Network error during upload. Please check your connection and try again. ($e)',
        'Error de red durante la carga. Revisa tu conexión e inténtalo de nuevo. ($e)',
      ));
    } finally {
      uploadComplete = true;
      // ignore: unawaited_futures
      pollerFuture;
    }
  }

  /// Decode a progress snapshot's `files` array into completed statuses.
  List<ImportFileStatus> _parseProgressFiles(Map<String, dynamic> snap) {
    final raw = snap['files'];
    final out = <ImportFileStatus>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final name = e['name']?.toString() ?? '';
          final ok = e['ok'] as bool? ?? true;
          final count = (e['count'] as num?)?.toInt() ?? 0;
          if (name.isNotEmpty) {
            out.add(ImportFileStatus(name, ok ? 'ok' : 'failed', count));
          }
        }
      }
    }
    return out;
  }

  /// One-shot fetch of the terminal snapshot, used to reconcile the
  /// checklist after the POST returns (the background poller may have
  /// stopped before observing the terminal state).
  Future<void> _fetchFinalProgress(
      String jobId, void Function(List<ImportFileStatus>) onFiles) async {
    try {
      final res = await _get(Uri.parse('$_baseUrl/imports/progress/$jobId'));
      if (res.statusCode == 200) {
        final snap = json.decode(res.body) as Map<String, dynamic>;
        onFiles(_parseProgressFiles(snap));
      }
    } catch (_) {
      // Best-effort; the merged response is still authoritative.
    }
  }

  /// Generate a job-id for the upload progress side-channel. Format
  /// is a 36-char UUID-shaped string so the backend's `Uuid::parse_str`
  /// accepts it cleanly. Not cryptographically random — the only
  /// requirement is uniqueness across concurrent uploads from the
  /// same browser tab.
  String _generateJobId() {
    final r = math.Random.secure();
    String hex(int n) {
      final buf = StringBuffer();
      for (int i = 0; i < n; i++) {
        buf.write(r.nextInt(16).toRadixString(16));
      }
      return buf.toString();
    }

    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  /// Poll `/imports/progress/{jobId}` every 250 ms until the server
  /// returns a terminal snapshot OR the upload completes (signalled
  /// by `done()` returning true). Each snapshot fires `onProgress`.
  /// Errors are swallowed — the upload itself is the authoritative
  /// channel, so a transient 404/500 on the polling side shouldn't
  /// surface as a user-visible failure.
  Future<void> _pollUploadProgress(
    String jobId,
    void Function(List<ImportFileStatus> completed) onFiles,
    bool Function() done,
  ) async {
    const interval = Duration(milliseconds: 250);
    int lastDone = -1;
    while (!done()) {
      await Future.delayed(interval);
      try {
        final res = await _get(
          Uri.parse('$_baseUrl/imports/progress/$jobId'),
        );
        if (res.statusCode == 200) {
          final snap = json.decode(res.body) as Map<String, dynamic>;
          final d = (snap['done'] as num?)?.toInt() ?? 0;
          final terminal = snap['terminal'] as bool? ?? false;
          // Only fire when the snapshot actually moved — saves the
          // import screen from rebuilding 4× per second when nothing's
          // changed.
          if (d != lastDone || terminal) {
            lastDone = d;
            onFiles(_parseProgressFiles(snap));
          }
          if (terminal) return;
        }
        // 404 means the job entry hasn't been registered yet (we
        // raced the upload handler) or has been evicted. Keep
        // polling — eventually `done()` will flip.
      } catch (_) {
        // Best-effort. Continue.
      }
    }
  }

  Future<Map<String, dynamic>> uploadStatement(
    String fileName,
    Uint8List bytes, {
    String? password,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/imports/upload'),
    );
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: fileName),
    );
    if (password != null && password.isNotEmpty) {
      request.fields['password'] = password;
    }

    try {
      final streamedResponse = await _client.send(request).timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamedResponse);
      _maybeUnauthorized(response);

      if (response.statusCode == 200) {
        // See uploadStatements: multipart bypasses the verb wrappers.
        clearDashboardCache();
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception(_t(
          'Server returned ${response.statusCode}: ${response.body}',
          'El servidor respondió ${response.statusCode}: ${response.body}',
        ));
      }
    } on http.ClientException catch (e) {
      throw Exception(_t(
        'Network error during upload. Please check your connection and try again. ($e)',
        'Error de red durante la carga. Revisa tu conexión e inténtalo de nuevo. ($e)',
      ));
    } catch (e) {
      throw Exception(_t('Upload failed: $e', 'La carga falló: $e'));
    }
  }

  Future<Map<String, dynamic>> confirmImport(
    String accountId,
    List<dynamic> transactions,
  ) async {
    final response = await _post(
      Uri.parse('$_baseUrl/imports/confirm'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'account_id': accountId,
        'transactions': transactions,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(_t('Confirmation failed: ${response.body}',
          'La confirmación falló: ${response.body}'));
    }
  }

  /// Attach statement-derived holdings (e.g. an HSA's invested fund + cash
  /// sleeve) to a manual account. Each [holdings] entry is a map
  /// {symbol, name?, quantity, value?, cash?}; same-symbol rows are replaced,
  /// then the account balance is recomputed from its holdings. Best-effort —
  /// a non-manual target returns 403, which the caller can ignore.
  Future<void> importHoldings(String accountId, List<dynamic> holdings) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/import'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'holdings': holdings}),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Holdings import failed: ${response.body}',
          'La importación de posiciones falló: ${response.body}'));
    }
  }

  /// Recent import batches (newest first): each is
  /// {batch_id, account_id, account_name, txn_count, from_date, to_date,
  /// imported_at, files[]}.
  Future<List<dynamic>> getImportBatches() async {
    final res = await _get(Uri.parse('$_baseUrl/imports/batches'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['batches'] as List?) ?? const [];
    }
    return const [];
  }

  /// Per-account statement-continuity status over the whole imported
  /// history: each is {account_id, account_name, institution_name,
  /// statement_count, warnings[]}. Empty `warnings` = no detected gaps.
  Future<List<dynamic>> getImportContinuity() async {
    final res = await _get(Uri.parse('$_baseUrl/imports/continuity'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['accounts'] as List?) ?? const [];
    }
    return const [];
  }

  /// Undo an import — delete every transaction it created. Returns the
  /// number removed.
  Future<int> undoImportBatch(String batchId) async {
    final res = await _delete(Uri.parse('$_baseUrl/imports/batches/$batchId'));
    if (res.statusCode == 200) {
      clearDashboardCache();
      return ((json.decode(res.body) as Map)['deleted'] as num?)?.toInt() ?? 0;
    }
    throw Exception(
        _t('Failed to undo import', 'No se pudo deshacer la importación'));
  }

  /// Bulk-delete transactions in an account + inclusive date range. With
  /// [dryRun] true, returns the count that WOULD be deleted (for a confirm
  /// preview); otherwise deletes and returns the number removed.
  /// [importedOnly] limits it to statement-imported rows.
  Future<int> bulkDeleteTransactions({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    required bool importedOnly,
    required bool dryRun,
  }) async {
    final res = await _post(
      Uri.parse('$_baseUrl/imports/transactions/bulk-delete'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'account_id': accountId,
        'date_from': dateFrom,
        'date_to': dateTo,
        'imported_only': importedOnly,
        'dry_run': dryRun,
      }),
    );
    if (res.statusCode == 200) {
      if (!dryRun) clearDashboardCache();
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body[dryRun ? 'count' : 'deleted'] as num?)?.toInt() ?? 0;
    }
    throw Exception(_t('Bulk delete failed', 'La eliminación masiva falló'));
  }

  /// Preview-time duplicate check: returns the indices (into
  /// [transactions]) that are already imported in [accountId], by the same
  /// signature confirm dedups on. Best-effort — returns an empty set on
  /// any error so the preview still works.
  Future<Set<int>> checkImportDuplicates(
    String accountId,
    List<dynamic> transactions,
  ) async {
    try {
      final response = await _post(
        Uri.parse('$_baseUrl/imports/check-duplicates'),
        headers: _withCsrf({'Content-Type': 'application/json'}),
        body: json.encode({
          'account_id': accountId,
          'transactions': transactions,
        }),
      );
      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final idx = (body['duplicate_indices'] as List?) ?? const [];
        return idx.map((e) => (e as num).toInt()).toSet();
      }
    } catch (_) {
      // Best-effort; fall through to "no duplicates known".
    }
    return <int>{};
  }

  /// Bump an account's `current_balance` and write a `balance_snapshots`
  /// row. `notes` (when set) is stored alongside the snapshot — used by
  /// manual-asset revaluations to capture "why this value moved" without
  /// stomping previous notes.
  Future<void> updateAccountBalance(
    String accountId,
    double balance, {
    String? notes,
  }) async {
    final body = <String, dynamic>{'current_balance': balance};
    if (notes != null && notes.trim().isNotEmpty) {
      body['notes'] = notes.trim();
    }
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/$accountId/balance'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to update balance',
          'No se pudo actualizar el saldo'));
    }
  }

  Future<void> deleteAccount(String accountId) async {
    final response = await _delete(Uri.parse('$_baseUrl/accounts/$accountId'));
    if (response.statusCode != 204) {
      throw Exception(_t('Failed to delete account',
          'No se pudo eliminar la cuenta'));
    }
  }

  /// Set or clear a user-defined nickname for an account. An empty
  /// nickname clears the override so display falls back to the
  /// bank-supplied name.
  Future<void> renameAccount(String accountId, String nickname) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/$accountId/nickname'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'nickname': nickname}),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to rename account',
          'No se pudo renombrar la cuenta'));
    }
  }

  Future<void> updateTransaction(
    String txId, {
    String? userCategory,
    String? userNotes,
    String? accountId,
    // `userDescription` semantics: null = leave alone, empty string =
    // clear the override (revert to the auto-picked label), any other
    // value = set the display override to that string.
    String? userDescription,
  }) async {
    final body = <String, dynamic>{};
    if (userCategory != null) body['user_category'] = userCategory;
    if (userNotes != null) body['user_notes'] = userNotes;
    if (accountId != null) body['account_id'] = accountId;
    if (userDescription != null) body['user_description'] = userDescription;

    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to update transaction',
          'No se pudo actualizar el movimiento'));
    }
  }

  /// Apply the same change (category and/or account move) to many
  /// transactions in ONE request — used by the bulk-action toolbar so a
  /// 40-row selection is a single round-trip, not 40 PATCHes. Only the
  /// non-null fields are sent (COALESCE semantics on the server: an
  /// absent field leaves that column alone). Returns the number of rows
  /// the server actually updated (ids the user doesn't own are filtered
  /// out by the `user_id` predicate and never counted). The `_patch`
  /// wrapper invalidates the dashboard cache on success, like every
  /// other mutation here.
  Future<int> batchUpdateTransactions(
    List<String> ids, {
    String? category,
    String? accountId,
    String? description,
  }) async {
    final body = <String, dynamic>{
      'ids': ids,
      if (category != null) 'user_category': category,
      if (accountId != null) 'account_id': accountId,
      if (description != null) 'user_description': description,
    };
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/transactions/batch'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to batch-update transactions',
          'No se pudieron actualizar los movimientos en lote'));
    }
    final decoded = json.decode(response.body) as Map<String, dynamic>;
    return (decoded['updated'] as num).toInt();
  }

  /// URL of the CSV export endpoint. We hand this to the browser via an
  /// anchor click rather than fetching + blobbing in Dart — the backend
  /// returns Content-Disposition: attachment so the browser downloads
  /// directly without using extra memory.
  String exportTransactionsCsvUrl() => '$_baseUrl/dashboard/transactions/export';

  /// Insert a manually-entered transaction. Positive amount = expense /
  /// outflow, negative = income / inflow (same convention as Plaid).
  Future<void> createManualTransaction({
    required String accountId,
    required DateTime date,
    required String description,
    required double amount,
    required String currency,
    String? category,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'account_id': accountId,
      'date': '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
      'description': description,
      'amount': amount,
      'currency': currency,
      if (category != null && category.isNotEmpty) 'category': category,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };
    final response = await _post(
      Uri.parse('$_baseUrl/dashboard/transactions/manual'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 409) {
      throw Exception(_t('Already added — same date / amount / description.',
          'Ya se agregó — misma fecha / monto / descripción.'));
    }
    if (response.statusCode != 201) {
      throw Exception(_t('Failed to add transaction: ${response.body}',
          'No se pudo agregar el movimiento: ${response.body}'));
    }
  }

  /// Split a transaction into [splits] children. Each split is
  /// `{description, amount, [category]}`. The original parent stays
  /// in the DB for audit but is hidden from every list view.
  Future<void> splitTransaction(
    String txId,
    List<Map<String, dynamic>> splits,
  ) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts/transactions/$txId/splits'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'splits': splits}),
    );
    if (response.statusCode != 201) {
      // Surface the server's reason (422 with `error` field) so the
      // dialog can show "Split total doesn't match" etc. exactly as
      // the server saw it.
      throw _errorFromBody(response,
          fallback: _t('Split failed', 'No se pudo dividir el movimiento'));
    }
  }

  /// Replace the children of an already-split parent in one atomic
  /// round-trip. Used by the "Edit split" flow — superior to
  /// unsplit-then-resplit because there's no window where a concurrent
  /// dashboard read sees the parent restored without children. The
  /// payload shape matches `splitTransaction`.
  Future<void> replaceSplits(
    String txId,
    List<Map<String, dynamic>> splits,
  ) async {
    final response = await _put(
      Uri.parse('$_baseUrl/accounts/transactions/$txId/splits'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'splits': splits}),
    );
    if (response.statusCode != 200) {
      throw _errorFromBody(response,
          fallback: _t('Edit split failed',
              'No se pudo editar la división'));
    }
  }

  /// Delete every child of a split parent — un-splits the transaction.
  /// The parent re-emerges in the list.
  Future<void> unsplitTransaction(String parentTxId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/accounts/transactions/$parentTxId/splits'),
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw _errorFromBody(response,
          fallback: _t('Unsplit failed',
              'No se pudo deshacer la división'));
    }
  }

  Future<void> deleteTransaction(String txId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception(_t(
          'Failed to delete transaction (${response.statusCode})',
          'No se pudo eliminar el movimiento (${response.statusCode})'));
    }
  }

  Future<void> createAccount({
    required String name,
    required String type,
    required String currency,
    required double initialBalance,
    String? clabe,
    String? holderName,
    String? institutionName,
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'name': name,
        'account_type': type,
        'currency': currency,
        'initial_balance': initialBalance,
        if (clabe != null && clabe.isNotEmpty) 'clabe': clabe,
        if (holderName != null && holderName.isNotEmpty) 'holder_name': holderName,
        if (institutionName != null && institutionName.isNotEmpty)
          'institution_name': institutionName,
      }),
    );
    if (response.statusCode != 201) {
      throw Exception(_t('Failed to create account: ${response.body}',
          'No se pudo crear la cuenta: ${response.body}'));
    }
  }

  // --- Manual holdings (ticker + share quantity, live-priced) ---------------

  Future<List<dynamic>> getAccountHoldings(String accountId) async {
    final res = await _get(Uri.parse('$_baseUrl/accounts/$accountId/holdings'));
    if (res.statusCode != 200) return const [];
    final body = json.decode(res.body);
    return body is List ? body : const [];
  }

  Future<Map<String, dynamic>> createHolding(
    String accountId, {
    required String symbol,
    required double quantity,
    String? name,
    double? costBasis,
  }) async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'symbol': symbol,
        'quantity': quantity,
        if (name != null && name.isNotEmpty) 'name': name,
        if (costBasis != null) 'cost_basis': costBasis,
      }),
    );
    if (res.statusCode != 201) {
      throw Exception(_t('Failed to add holding: ${res.body}',
          'No se pudo agregar la posición: ${res.body}'));
    }
    return json.decode(res.body) as Map<String, dynamic>;
  }

  Future<void> deleteHolding(String accountId, String holdingId) async {
    final res = await _delete(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/$holdingId'),
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw Exception(_t('Failed to remove holding', 'No se pudo eliminar la posición'));
    }
  }

  Future<List<dynamic>> refreshHoldings(String accountId) async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/$accountId/holdings/refresh'),
      headers: _withCsrf({}),
    );
    if (res.statusCode != 200) return const [];
    final body = json.decode(res.body);
    return body is List ? body : const [];
  }

  /// Re-price every manual stock holding the user has (across all manual
  /// accounts) from the live quote cache. Returns counts; best-effort.
  Future<Map<String, dynamic>> refreshAllStockPrices() async {
    final res = await _post(
      Uri.parse('$_baseUrl/accounts/holdings/refresh-all'),
      headers: _withCsrf({}),
    );
    if (res.statusCode != 200) return const {};
    final body = json.decode(res.body);
    return body is Map<String, dynamic> ? body : const {};
  }

  /// Per-holding dividend info (annual rate, yield, est. next ex-date,
  /// projected annual income). Best-effort — empty on failure.
  Future<List<dynamic>> getHoldingsDividends(String accountId) async {
    final res =
        await _get(Uri.parse('$_baseUrl/accounts/$accountId/holdings/dividends'));
    if (res.statusCode != 200) return const [];
    final body = json.decode(res.body);
    return body is List ? body : const [];
  }

  Future<Map<String, dynamic>> getWealthProjection({
    required double startBalance,
    required double monthlyContribution,
    required double annualReturnRate,
    required double annualExpenses,
    required double withdrawalRate,
    int years = 30,
    double annualInflationRate = 0.03,
    double returnVolatility = 0.13,
    int? yearsToRetirement,
    int monteCarloTrials = 1000,
    double baristaMonthlyIncome = 0.0,
    double annualTaxDrag = 0.0,
    bool withdrawalGuardrails = false,
  }) async {
    final queryParams = {
      'start_balance': startBalance.toString(),
      'monthly_contribution': monthlyContribution.toString(),
      'annual_return_rate': annualReturnRate.toString(),
      'annual_expenses': annualExpenses.toString(),
      'withdrawal_rate': withdrawalRate.toString(),
      'years': years.toString(),
      'annual_inflation_rate': annualInflationRate.toString(),
      'return_volatility': returnVolatility.toString(),
      'monte_carlo_trials': monteCarloTrials.toString(),
      'barista_monthly_income': baristaMonthlyIncome.toString(),
      'annual_tax_drag': annualTaxDrag.toString(),
      'withdrawal_guardrails': withdrawalGuardrails.toString(),
      if (yearsToRetirement != null)
        'years_to_retirement': yearsToRetirement.toString(),
    };

    final uri = Uri.parse(
      '$_baseUrl/projections/calculate',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load wealth projection',
        'No se pudo cargar la proyección de patrimonio'));
  }

  /// Projection inputs derived from the user's tracked cash flow (USD).
  /// Returns null on any error so the screen falls back to static defaults.
  Future<Map<String, dynamic>?> getProjectionDefaults() async {
    try {
      final response =
          await _get(Uri.parse('$_baseUrl/projections/defaults'));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
    } catch (_) {
      // Best-effort prefill; the screen has sensible static defaults.
    }
    return null;
  }

  Future<void> linkCryptoInstitution({
    required String name,
    required String integrationType,
    required String apiKey,
    required String apiSecret,
    String? apiPass,
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/crypto'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'name': name,
        'integration_type': integrationType,
        'api_key': apiKey,
        'api_secret': apiSecret,
        'api_pass': apiPass,
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception(_t('Failed to link crypto: ${response.body}',
          'No se pudo vincular el exchange de cripto: ${response.body}'));
    }
  }

  Future<Map<String, dynamic>> getTaxSummary({
    int? year,
    String? status,
  }) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();
    if (status != null) queryParams['status'] = status;

    final uri = Uri.parse(
      '$_baseUrl/tax/summary',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load tax summary',
        'No se pudo cargar el resumen fiscal'));
  }

  Future<List<dynamic>> getTaxTransactions({int? year}) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();

    final uri = Uri.parse(
      '$_baseUrl/tax/transactions',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load tax transactions',
        'No se pudieron cargar los movimientos fiscales'));
  }

  /// Realized capital-gains disposals (Form 8949-style detail) behind the
  /// summary's ST/LT figures, newest sell date first. Each row carries its
  /// `tax_advantaged` flag so the screen can split or badge wrapper-account
  /// disposals separately. Returns the raw decoded JSON list.
  Future<List<dynamic>> getTaxDisposals(int year) async {
    final uri = Uri.parse(
      '$_baseUrl/tax/disposals',
    ).replace(queryParameters: {'year': year.toString()});
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load realized gains',
        'No se pudieron cargar las ganancias realizadas'));
  }

  /// Unrealized per-lot "what if I sell" view for taxable accounts (T11):
  /// per-lot signed USD gain/loss, short/long-term term with
  /// `days_until_long_term`, and loss-harvest candidates carrying an
  /// `estimated_tax_savings_usd` and a forward-looking `wash_sale_risk` guard.
  /// The savings and marginal rates ride the UNVERIFIED constant tables, so
  /// the response's `constants_verified` flag must gate how authoritative the
  /// figures are shown. `status` is optional; the backend falls back to the
  /// persisted filing status. Returns the raw decoded JSON map (`lots` plus
  /// ST/LT subtotals, marginal rates, and the verification context).
  Future<Map<String, dynamic>> getUnrealizedLots({
    int? year,
    String? status,
  }) async {
    final queryParams = <String, String>{};
    if (year != null) queryParams['year'] = year.toString();
    if (status != null) queryParams['status'] = status;

    final uri = Uri.parse(
      '$_baseUrl/tax/unrealized',
    ).replace(queryParameters: queryParams);
    final response = await _get(uri);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load unrealized positions',
        'No se pudieron cargar las posiciones no realizadas'));
  }

  /// Sync a single institution. Cheaper than the global sync when only
  /// one or two institutions are stuck.
  Future<void> syncInstitution(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/$institutionId/sync'),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Sync failed: ${response.statusCode}',
          'La sincronización falló: ${response.statusCode}'));
    }
  }

  /// Push the currently-configured PLAID_WEBHOOK_URL onto every Plaid
  /// item the caller owns via Plaid's /item/webhook/update. Used after
  /// the operator first sets the env var on a deployment that already
  /// has linked items — Plaid binds the webhook URL at link-time, so
  /// pre-existing items keep polling forever unless either re-linked
  /// or pointed at the new URL via this endpoint.
  ///
  /// Returns `{ "updated": int, "failed": int, "webhook_url": str,
  /// "results": [{ "id", "name", "ok", "reason"? }] }`.
  Future<Map<String, dynamic>> updateWebhooks() async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/update-webhook'),
    );
    if (response.statusCode != 200) {
      throw Exception(_t(
        'Update webhook failed (${response.statusCode}): ${response.body}',
        'No se pudo actualizar el webhook (${response.statusCode}): ${response.body}',
      ));
    }
    return json.decode(response.body);
  }

  /// Sync an arbitrary set of institutions in one round-trip. Replaces
  /// the client-side loop the "Retry N failed" shortcut used to do.
  Future<void> syncInstitutionsBatch(List<String> institutionIds) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/sync'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'ids': institutionIds}),
    );
    if (response.statusCode != 200) {
      throw Exception(_t('Batched sync failed: ${response.statusCode}',
          'La sincronización en lote falló: ${response.statusCode}'));
    }
  }

  /// Generic app-setting store. The backend returns JSON null when the
  /// key has never been written; callers should treat that as "absent".
  Future<dynamic> getSetting(String key) async {
    final response = await _get(Uri.parse('$_baseUrl/settings/$key'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception(_t('Failed to load setting $key',
        'No se pudo cargar la configuración $key'));
  }

  Future<void> putSetting(String key, dynamic value) async {
    final response = await _put(
      Uri.parse('$_baseUrl/settings/$key'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(value),
    );
    if (response.statusCode != 200) {
      throw Exception(_t(
          'Failed to save setting $key (${response.statusCode})',
          'No se pudo guardar la configuración $key (${response.statusCode})'));
    }
  }

  // ---------- Personal lending ----------

  Future<List<dynamic>> getLoans() async {
    // No trailing slash: axum 0.8 nest("/api/loans") + inner "/" route
    // matches /api/loans but NOT /api/loans/ (the latter 404s).
    final response = await _get(Uri.parse('$_baseUrl/loans'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(_t('Failed to load loans',
        'No se pudieron cargar los préstamos'));
  }

  Future<Map<String, dynamic>> getLoansSummary({bool forceRefresh = false}) {
    return _cachedGet('loans/summary', () async {
      final response = await _get(Uri.parse('$_baseUrl/loans/summary'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_t('Failed to load loans summary',
          'No se pudo cargar el resumen de préstamos'));
    }, forceRefresh: forceRefresh);
  }

  Future<List<dynamic>> getLoanPeople() async {
    final response = await _get(Uri.parse('$_baseUrl/loans/people'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(_t('Failed to load people',
        'No se pudieron cargar las personas'));
  }

  Future<Map<String, dynamic>> createLoan({
    required String borrowerName,
    required double principal,
    required String currency,
    required DateTime originationDate,
    double interestRate = 0,
    String interestType = 'none',
    String ratePeriod = 'annual',
    int? termMonths,
    String? paymentFrequency,
    String? notes,
    String? personId,
    DateTime? expectedRepaymentDate,
  }) async {
    final body = <String, dynamic>{
      'borrower_name': borrowerName,
      'principal': principal,
      'currency': currency,
      'origination_date': _isoDate(originationDate),
      'interest_rate': interestRate,
      'interest_type': interestType,
      'rate_period': ratePeriod,
      if (termMonths != null) 'term_months': termMonths,
      if (paymentFrequency != null) 'payment_frequency': paymentFrequency,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (personId != null) 'person_id': personId,
      if (expectedRepaymentDate != null)
        'expected_repayment_date': _isoDate(expectedRepaymentDate),
    };
    final response = await _post(
      // No trailing slash — see getLoans (axum nest routing).
      Uri.parse('$_baseUrl/loans'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(_t('Failed to create loan (${response.statusCode})',
        'No se pudo crear el préstamo (${response.statusCode})'));
  }

  /// Patch a loan. The status-only call sites pass `{'status': ...}`
  /// positionally; the edit dialog passes the full editable field set
  /// (borrower_name / principal / interest_rate / interest_type / notes)
  /// in [changes], and may additionally set any of the optional named
  /// params, which are merged into the body when non-null (taking
  /// precedence over the same key in [changes]). interest_rate must
  /// already be a fraction (percent ÷ 100), mirroring createLoan.
  ///
  /// A parallel backend change may now regenerate the schedule when
  /// principal/rate/interest_type change and reject term changes on a
  /// reconciled loan with 409 — surfaced here as [LoanTermsLockedException]
  /// so the caller can show the server's message instead of crashing.
  Future<void> updateLoan(
    String id,
    Map<String, dynamic> changes, {
    String? borrowerName,
    double? principal,
    double? interestRate,
    String? interestType,
    String? notes,
    DateTime? expectedRepaymentDate,
  }) async {
    final body = <String, dynamic>{
      ...changes,
      if (borrowerName != null) 'borrower_name': borrowerName,
      if (principal != null) 'principal': principal,
      if (interestRate != null) 'interest_rate': interestRate,
      if (interestType != null) 'interest_type': interestType,
      if (notes != null) 'notes': notes,
      if (expectedRepaymentDate != null)
        'expected_repayment_date': _isoDate(expectedRepaymentDate),
    };
    final response = await _patch(
      Uri.parse('$_baseUrl/loans/$id'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode == 409) {
      throw LoanTermsLockedException(_loanErrorText(response));
    }
    if (response.statusCode != 200) {
      throw Exception(_t('Failed to update loan (${response.statusCode})',
          'No se pudo actualizar el préstamo (${response.statusCode})'));
    }
  }

  /// Pull a human-readable message out of a loan error response: the
  /// backend returns either a bare string body or a `{error: "..."}`
  /// JSON object depending on the path. Falls back to a generic message.
  String _loanErrorText(http.Response res) {
    final body = res.body.trim();
    if (body.isEmpty) {
      return _t('This change isn\'t allowed.', 'Este cambio no está permitido.');
    }
    try {
      final decoded = json.decode(body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Not JSON — the backend often returns a plain-text reason.
    }
    return body;
  }

  Future<void> deleteLoan(String id) async {
    final response = await _delete(Uri.parse('$_baseUrl/loans/$id'));
    if (response.statusCode != 204) {
      throw Exception(_t('Failed to delete loan (${response.statusCode})',
          'No se pudo eliminar el préstamo (${response.statusCode})'));
    }
  }

  Future<List<dynamic>> getLoanPayments(String loanId) async {
    final response = await _get(Uri.parse('$_baseUrl/loans/$loanId/payments'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(_t('Failed to load loan payments',
        'No se pudieron cargar los pagos del préstamo'));
  }

  Future<void> linkDisbursement(String loanId, String transactionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/disbursement'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'transaction_id': transactionId}),
    );
    if (response.statusCode != 200) {
      throw Exception(_t(
          'Failed to link disbursement (${response.statusCode})',
          'No se pudo vincular el desembolso (${response.statusCode})'));
    }
  }

  /// Record a repayment. Pass [transactionId] to designate a bank inflow,
  /// or omit it for a cash/off-bank payment (then [amount] is required).
  /// [paidDate] is an ISO yyyy-MM-dd string; defaults server-side to the
  /// tx date (linked) or today (cash).
  Future<void> recordRepayment(
    String loanId, {
    String? transactionId,
    double? amount,
    String? paidDate,
  }) async {
    final body = <String, dynamic>{};
    if (transactionId != null) body['transaction_id'] = transactionId;
    if (amount != null) body['amount'] = amount;
    if (paidDate != null) body['paid_date'] = paidDate;
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/payments'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(body),
    );
    if (response.statusCode != 201) {
      throw Exception(response.body.isNotEmpty
          ? response.body
          : _t('Failed to record repayment (${response.statusCode})',
              'No se pudo registrar el pago (${response.statusCode})'));
    }
  }

  /// (Re)generate a loan's amortization schedule. 409 if any payment is
  /// already reconciled; 422 if the loan is open-ended (no term/freq).
  Future<void> generateLoanSchedule(String loanId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/schedule'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({}),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      // Surface the server's human message (409/422 carry useful text).
      throw Exception(response.body.isNotEmpty
          ? response.body
          : _t('Failed to generate schedule (${response.statusCode})',
              'No se pudo generar el calendario de pagos (${response.statusCode})'));
    }
  }

  /// Administrative early/full payoff: closes the loan (status →
  /// paid_off) and voids the remaining unpaid scheduled installments.
  /// Does NOT create a payment — the user reconciles the real final
  /// transaction through the normal repayment flow (cash-basis interest
  /// income only counts money that actually arrived). 409 if the loan
  /// isn't active.
  Future<void> payoffLoan(String loanId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/loans/$loanId/payoff'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({}),
    );
    if (response.statusCode != 200) {
      throw Exception(response.body.isNotEmpty
          ? response.body
          : _t('Failed to pay off loan (${response.statusCode})',
              'No se pudo liquidar el préstamo (${response.statusCode})'));
    }
  }

  /// Interest-income report (cash basis). `year` optional. Returns
  /// {year, total_interest, total_principal, by_loan[], by_month[]}.
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async {
    final q = year != null ? '?year=$year' : '';
    final response =
        await _get(Uri.parse('$_baseUrl/loans/interest-income$q'));
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception(_t('Failed to load interest income',
        'No se pudieron cargar los ingresos por intereses'));
  }

  /// Direct download URL for the loan-interest CSV (opened in the
  /// browser so the cookie auth rides along, like the tx export).
  String interestIncomeCsvUrl({int? year}) {
    final q = year != null ? '?year=$year' : '';
    return '$_baseUrl/loans/interest-income/export$q';
  }

  /// Per-borrower per-year interest totals CSV (Schedule-B style).
  String interestSummaryCsvUrl() =>
      '$_baseUrl/loans/interest-income/summary';

  /// Printable promissory-note / agreement HTML for a loan (opened in
  /// a new tab; the user prints to PDF from the browser).
  String loanAgreementUrl(String loanId) =>
      '$_baseUrl/loans/$loanId/agreement';

  /// Borrower-facing printable payment plan (HTML → browser PDF): the
  /// schedule with a running balance, friendlier than the legal
  /// agreement. Opened in a new tab so cookie auth rides along.
  String loanPaymentPlanUrl(String loanId) => '$_baseUrl/loans/$loanId/plan';

  /// The payment plan as a CSV that opens directly in Google Sheets /
  /// Excel (installment, due date, principal/interest split, balance
  /// remaining). Opened in a new tab to trigger the download.
  String loanScheduleCsvUrl(String loanId) =>
      '$_baseUrl/loans/$loanId/schedule.csv';

  /// Upcoming + overdue installments for the notifications bell. Each
  /// item: {loan_id, payment_id, borrower_name, amount, currency,
  /// due_date, installment_number, days_until, days_overdue}.
  Future<List<dynamic>> getLoanReminders({bool forceRefresh = false}) {
    return _cachedGet('loans/reminders', () async {
      final response = await _get(Uri.parse('$_baseUrl/loans/reminders'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as List<dynamic>;
      }
      throw Exception(_t('Failed to load loan reminders',
          'No se pudieron cargar los recordatorios de préstamos'));
    }, forceRefresh: forceRefresh);
  }

  /// Unlink (un-reconcile) a recorded repayment. The bank transaction
  /// itself is untouched; only the loan_payments row is removed.
  Future<void> deleteLoanPayment(String paymentId) async {
    final response =
        await _delete(Uri.parse('$_baseUrl/loans/payments/$paymentId'));
    if (response.statusCode != 204) {
      throw Exception(_t('Failed to unlink payment (${response.statusCode})',
          'No se pudo desvincular el pago (${response.statusCode})'));
    }
  }

  /// Auto-suggest reconciliation candidates. `kind` is 'disbursement'
  /// or 'repayment'. Each item: {transaction_id, date, amount, currency,
  /// description, confidence, name_matched}.
  Future<List<dynamic>> getLoanSuggestions(String loanId, String kind) async {
    final response =
        await _get(Uri.parse('$_baseUrl/loans/$loanId/suggestions/$kind'));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception(_t('Failed to load suggestions',
        'No se pudieron cargar las sugerencias'));
  }

  /// Date as YYYY-MM-DD (the backend's NaiveDate format).
  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
