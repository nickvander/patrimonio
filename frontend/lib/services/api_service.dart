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
/// `done` is the count of files that have finished parsing
/// (regardless of success/failure); `total` is the batch size from
/// the initial `started` event. `lastFile` is the most recently
/// completed file name + ok flag. The import screen uses these to
/// render "N of M done: foo.pdf" in real time while a large batch
/// of PDFs is parsing on the server.
typedef ImportProgressCallback = void Function({
  required int done,
  required int total,
  String? lastFile,
  bool? lastFileOk,
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
  /// `Future.wait` on EVERY reload (sub-screen return, realtime event,
  /// post-mutation refresh). Without caching, a single transaction rename
  /// re-pulled holdings, net-worth history, allocation, trends, etc. The
  /// cache collapses redundant reads inside the TTL window and de-dupes
  /// concurrent identical GETs into one network call.
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

  Future<List<dynamic>> getAccountTransactions(String accountId) async {
    final response = await _get(
      Uri.parse('$_baseUrl/accounts/$accountId/transactions'),
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
  }) async {
    if (files.isEmpty) {
      throw Exception(_t('No files to upload',
          'No hay archivos para subir'));
    }
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/imports/upload'),
    );
    // Mirror the protected router's CSRF guard. The multipart
    // helper bypasses our _post wrapper, so the header has to be
    // attached by hand. Value matches `_csrfHeader` everywhere
    // else.
    request.headers['X-Requested-With'] = 'fetch';

    // When a progress callback is supplied, tag the request with a
    // UUID the server will key its progress entry on. We use a
    // simple time+random scheme rather than pulling in `uuid`
    // (the package is already a transitive dep but not surfaced).
    final String? jobId = onProgress != null ? _generateJobId() : null;
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

    // Kick off the polling loop concurrently with the upload. It
    // self-terminates when the server marks the job terminal OR
    // when this scope completes (we cancel via the bool flag).
    bool uploadComplete = false;
    Future<void>? pollerFuture;
    if (jobId != null && onProgress != null) {
      pollerFuture = _pollUploadProgress(
        jobId,
        onProgress,
        () => uploadComplete,
      );
    }

    try {
      // 600s (10 min) timeout. The backend parallelises PDF parsing
      // across the blocking pool, but each file is still CPU-bound
      // for several seconds (qpdf decrypt + lopdf extract + table
      // recovery). A worst-case batch — e.g. two years of monthly
      // Banamex PDFs on a busy single-vCPU VPS — can plausibly take
      // ~5 minutes; 600s gives a generous safety margin.
      final streamedResponse = await _client.send(request).timeout(
        const Duration(seconds: 600),
      );
      _maybeUnauthorizedStreamed(streamedResponse);

      final response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        // Multipart upload bypasses the _post/_patch verb wrappers, so the
        // central post-mutation invalidation doesn't fire here — clear by
        // hand. A successful import changes balances, holdings, txns, etc.
        clearDashboardCache();
        return json.decode(response.body) as Map<String, dynamic>;
      }
      // Payload-too-large surfaces as a real 413 OR (more often
      // through the axum multipart stack) as a truncated body that
      // makes parsing fail with 4xx/5xx. Give the user a specific
      // hint when the size pattern matches so they don't have to
      // guess.
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
      // 10 minutes elapsed without a response. We don't know whether
      // the server finished parsing or hit its own ceiling; advise
      // the user to either retry or split the batch rather than
      // surface the bare "TimeoutException" string.
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
      // Stop the poller as soon as the upload returns. The poller
      // also self-terminates on the next tick after we flip
      // `uploadComplete = true`.
      uploadComplete = true;
      if (pollerFuture != null) {
        // Don't await — the poller exits within ~250 ms; making
        // the caller wait that long would be visible UX latency
        // on top of an already-finished upload.
        // ignore: unawaited_futures
        pollerFuture;
      }
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
    ImportProgressCallback onProgress,
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
          final t = (snap['total'] as num?)?.toInt() ?? 0;
          final terminal = snap['terminal'] as bool? ?? false;
          // Only fire onProgress when the snapshot actually moved —
          // saves the import screen from rebuilding 4× per second
          // when nothing's changed.
          if (d != lastDone || terminal) {
            lastDone = d;
            onProgress(
              done: d,
              total: t,
              lastFile: snap['last_file']?.toString(),
              lastFileOk: snap['last_ok'] as bool?,
            );
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
  }) async {
    final response = await _post(
      Uri.parse('$_baseUrl/accounts'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        'name': name,
        'account_type': type,
        'currency': currency,
        'initial_balance': initialBalance,
      }),
    );
    if (response.statusCode != 201) {
      throw Exception(_t('Failed to create account: ${response.body}',
          'No se pudo crear la cuenta: ${response.body}'));
    }
  }

  Future<Map<String, dynamic>> getWealthProjection({
    required double startBalance,
    required double monthlyContribution,
    required double annualReturnRate,
    required double annualExpenses,
    required double withdrawalRate,
    int years = 30,
  }) async {
    final queryParams = {
      'start_balance': startBalance.toString(),
      'monthly_contribution': monthlyContribution.toString(),
      'annual_return_rate': annualReturnRate.toString(),
      'annual_expenses': annualExpenses.toString(),
      'withdrawal_rate': withdrawalRate.toString(),
      'years': years.toString(),
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
  }) async {
    final body = <String, dynamic>{
      ...changes,
      if (borrowerName != null) 'borrower_name': borrowerName,
      if (principal != null) 'principal': principal,
      if (interestRate != null) 'interest_rate': interestRate,
      if (interestType != null) 'interest_type': interestType,
      if (notes != null) 'notes': notes,
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
