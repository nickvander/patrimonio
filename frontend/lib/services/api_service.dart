import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;
import 'auth_service.dart';

/// Thrown when the server returns 401. The auth gate listens for this
/// indirectly via AuthService.handleUnauthorized().
class UnauthorizedException implements Exception {
  final String message;
  UnauthorizedException([this.message = 'Authentication required']);
  @override
  String toString() => message;
}

class ApiService {
  String get _baseUrl {
    final host = web.window.location.hostname.isEmpty
        ? 'localhost'
        : web.window.location.hostname;
    return 'http://$host:8080/api';
  }

  String get baseUrl => _baseUrl;

  /// Shared credentialed HTTP client. `withCredentials` is required for
  /// the browser to send (and accept) the session cookie on cross-origin
  /// XHRs in development, and is harmless in same-origin production.
  static final BrowserClient _client = BrowserClient()..withCredentials = true;

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

  Future<http.Response> _get(Uri uri) async {
    final res = await _client.get(uri);
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _post(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.post(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _patch(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.patch(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _put(Uri uri, {Object? body, Map<String, String>? headers}) async {
    final res = await _client.put(uri, body: body, headers: _withCsrf(headers));
    _maybeUnauthorized(res);
    return res;
  }

  Future<http.Response> _delete(Uri uri) async {
    final res = await _client.delete(uri, headers: _csrfHeader);
    _maybeUnauthorized(res);
    return res;
  }

  void _maybeUnauthorized(http.Response res) {
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
    throw Exception('Failed to load auth status (${res.statusCode})');
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
    throw _errorFromBody(res, fallback: 'Login failed');
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
    throw _errorFromBody(res, fallback: 'TOTP verification failed');
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
    throw _errorFromBody(res, fallback: 'Bootstrap failed');
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
    throw _errorFromBody(res, fallback: 'Registration failed');
  }

  /// Mint a new invite token. Authenticated. Returns the plaintext
  /// token + a shareable URL (`<frontend>/?invite=<token>`) + the
  /// absolute expiry time in ISO 8601.
  Future<InviteMint> createInvite({int? expiresInHours, String? note}) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/invites'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({
        if (expiresInHours != null) 'expires_in_hours': expiresInHours,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
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
    throw _errorFromBody(res, fallback: 'Failed to mint invite');
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
    throw _errorFromBody(res, fallback: 'Failed to list invites');
  }

  Future<void> revokeInvite(String id) async {
    final res = await _client.delete(
      Uri.parse('$_baseUrl/auth/invites/$id'),
      headers: _csrfHeader,
    );
    _maybeUnauthorized(res);
    if (res.statusCode != 204) {
      throw _errorFromBody(res, fallback: 'Failed to revoke invite');
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
      throw _errorFromBody(res, fallback: 'Password reset failed');
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
    throw _errorFromBody(res, fallback: 'Regenerate failed');
  }

  Future<int> recoveryCodesCount() async {
    final res = await _get(Uri.parse('$_baseUrl/auth/recovery-codes/count'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['unused'] as num).toInt();
    }
    throw _errorFromBody(res, fallback: 'Count failed');
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
    throw _errorFromBody(res, fallback: 'TOTP enroll failed');
  }

  Future<void> confirmTotpEnroll(String code) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/totp/confirm'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'code': code}),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res, fallback: 'TOTP confirm failed');
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
      throw _errorFromBody(res, fallback: 'Disable TOTP failed');
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
    throw _errorFromBody(res, fallback: 'Failed to load sessions');
  }

  Future<void> revokeSession(String sessionId) async {
    final res = await _delete(
      Uri.parse('$_baseUrl/auth/sessions/$sessionId'),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(res, fallback: 'Failed to revoke session');
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
    throw _errorFromBody(res, fallback: 'Failed to revoke other sessions');
  }

  Future<void> logout() async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/logout'),
      headers: _csrfHeader,
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw _errorFromBody(res, fallback: 'Logout failed');
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
      throw _errorFromBody(res, fallback: 'Password change failed');
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

  Future<Map<String, dynamic>> getDashboardOverview() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/overview'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load dashboard overview');
  }

  Future<List<dynamic>> getNetWorthHistory() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/net-worth-history'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load net worth history');
  }

  Future<List<dynamic>> getAllocationData() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/allocation'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load allocation data');
  }

  Future<List<dynamic>> getTrendData() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/trends'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load trend data');
  }

  Future<Map<String, dynamic>> getHoldings() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/holdings'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load holdings');
  }

  Future<List<dynamic>> getCreditUtilization() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/credit-utilization'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load credit utilization');
  }

  Future<List<dynamic>> getSyncStatus() async {
    final response = await _get(Uri.parse('$_baseUrl/dashboard/sync-status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load sync status');
  }

  /// Summary of "what changed since your previous login" — used by the
  /// dismissible Overview banner. Returns null when the user has no
  /// previous login (first session ever), so the caller can skip rendering.
  Future<Map<String, dynamic>?> getSinceLastLogin() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/since-last-login'),
    );
    if (response.statusCode != 200) return null;
    final body = json.decode(response.body) as Map<String, dynamic>;
    // Backend signals "no previous login" by omitting `previous_login_at`.
    if (body['previous_login_at'] == null) return null;
    return body;
  }

  /// List every dismissed subscription merchant. Returned shape:
  /// `[{merchant_key, ignored_at}, ...]`.
  Future<List<dynamic>> getIgnoredSubscriptions() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/subscriptions/ignored'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load ignored subscriptions');
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
      throw Exception('Failed to un-ignore subscription');
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
      throw Exception('Failed to dismiss subscription');
    }
  }

  /// Detected recurring outflows (subscriptions, bills, gym, etc.).
  /// See `dashboard.rs::detected_subscriptions` for the heuristic.
  Future<List<dynamic>> getSubscriptions() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/subscriptions'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load subscriptions');
  }

  /// Linked cross-currency cash transfers. Each row pairs a USD-out
  /// with an MXN-in (or reverse) plus the implied FX rate Wise/Remitly
  /// gave the user.
  Future<List<dynamic>> getFxTransfers() async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/fx-transfers'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load FX transfers');
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
    throw Exception('FX detection failed');
  }

  Future<void> confirmFxTransfer(String id) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/$id'),
    );
    if (response.statusCode != 200) {
      throw Exception('Confirm failed (${response.statusCode})');
    }
  }

  Future<void> unlinkFxTransfer(String id) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/dashboard/fx-transfers/$id'),
    );
    if (response.statusCode != 204) {
      throw Exception('Unlink failed (${response.statusCode})');
    }
  }

  Future<Map<String, dynamic>> getSetupStatus() async {
    // Setup status is a public endpoint — used by the login screen — so
    // we still send credentials but the server does not require them.
    final response = await _client.get(Uri.parse('$_baseUrl/setup/status'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load setup status');
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
    throw Exception('Failed to load exchange rate');
  }

  Future<List<dynamic>> getTransactions({int limit = 50, int offset = 0}) async {
    final response = await _get(
      Uri.parse('$_baseUrl/dashboard/transactions?limit=$limit&offset=$offset'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load transactions');
  }

  Future<List<dynamic>> getAccountTransactions(String accountId) async {
    final response = await _get(
      Uri.parse('$_baseUrl/accounts/$accountId/transactions'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load account transactions');
  }

  Future<void> syncInstitutions() async {
    final response = await _post(Uri.parse('$_baseUrl/institutions/sync'));
    if (response.statusCode != 200) {
      throw Exception('Failed to sync institutions');
    }
  }

  Future<Map<String, dynamic>> getReconnectToken(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/reconnect-token/$institutionId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to retrieve reconnect token');
  }

  Future<void> deleteInstitution(String institutionId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/institutions/$institutionId'),
    );
    if (response.statusCode != 204) {
      throw Exception('Failed to delete institution');
    }
  }

  /// Multi-file batch wrapper around the same /imports/upload
  /// endpoint. The server accepts any number of `file` parts in a
  /// single multipart and parses each independently — much faster
  /// than 12 round-trips for a year of monthly statements, and lets
  /// the user confirm everything in one preview.
  Future<Map<String, dynamic>> uploadStatements(
    List<PlatformFile> files, {
    String? password,
  }) async {
    if (files.isEmpty) {
      throw Exception('No files to upload');
    }
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/imports/upload'),
    );
    for (final f in files) {
      if (f.bytes == null) continue;
      request.files.add(
        http.MultipartFile.fromBytes('file', f.bytes!, filename: f.name),
      );
    }
    if (password != null && password.isNotEmpty) {
      request.fields['password'] = password;
    }

    try {
      // 180s timeout. PDF parsing runs in a spawn_blocking task on
      // the backend and is CPU-bound per file; a batch of 12 monthly
      // statements can plausibly take 60-120 seconds total. The
      // previous 60s timeout was below that envelope and would
      // cancel the upload mid-parse.
      final streamedResponse = await _client.send(request).timeout(
        const Duration(seconds: 180),
      );
      final response = await http.Response.fromStream(streamedResponse);
      _maybeUnauthorized(response);

      if (response.statusCode == 200) {
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
        throw Exception(
          'Upload too large (${totalMb.toStringAsFixed(1)} MB across '
          '${files.length} file${files.length == 1 ? '' : 's'}). '
          'Try splitting into smaller batches.',
        );
      }
      throw Exception('Server returned ${response.statusCode}: ${response.body}');
    } on http.ClientException catch (e) {
      throw Exception(
        'Network error during upload. Please check your connection and try again. ($e)',
      );
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
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception(
          'Server returned ${response.statusCode}: ${response.body}',
        );
      }
    } on http.ClientException catch (e) {
      throw Exception(
        'Network error during upload. Please check your connection and try again. ($e)',
      );
    } catch (e) {
      throw Exception('Upload failed: $e');
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
      throw Exception('Confirmation failed: ${response.body}');
    }
  }

  Future<void> updateAccountBalance(String accountId, double balance) async {
    final response = await _patch(
      Uri.parse('$_baseUrl/accounts/$accountId/balance'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'current_balance': balance}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update balance');
    }
  }

  Future<void> deleteAccount(String accountId) async {
    final response = await _delete(Uri.parse('$_baseUrl/accounts/$accountId'));
    if (response.statusCode != 204) {
      throw Exception('Failed to delete account');
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
      throw Exception('Failed to rename account');
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
      throw Exception('Failed to update transaction');
    }
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
      throw Exception('Already added — same date / amount / description.');
    }
    if (response.statusCode != 201) {
      throw Exception('Failed to add transaction: ${response.body}');
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
      throw _errorFromBody(response, fallback: 'Split failed');
    }
  }

  /// Delete every child of a split parent — un-splits the transaction.
  /// The parent re-emerges in the list.
  Future<void> unsplitTransaction(String parentTxId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/accounts/transactions/$parentTxId/splits'),
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw _errorFromBody(response, fallback: 'Unsplit failed');
    }
  }

  Future<void> deleteTransaction(String txId) async {
    final response = await _delete(
      Uri.parse('$_baseUrl/accounts/transactions/$txId'),
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception('Failed to delete transaction (${response.statusCode})');
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
      throw Exception('Failed to create account: ${response.body}');
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
    throw Exception('Failed to load wealth projection');
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
      throw Exception('Failed to link crypto: ${response.body}');
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
    throw Exception('Failed to load tax summary');
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
    throw Exception('Failed to load tax transactions');
  }

  /// Sync a single institution. Cheaper than the global sync when only
  /// one or two institutions are stuck.
  Future<void> syncInstitution(String institutionId) async {
    final response = await _post(
      Uri.parse('$_baseUrl/institutions/$institutionId/sync'),
    );
    if (response.statusCode != 200) {
      throw Exception('Sync failed: ${response.statusCode}');
    }
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
      throw Exception('Batched sync failed: ${response.statusCode}');
    }
  }

  /// Generic app-setting store. The backend returns JSON null when the
  /// key has never been written; callers should treat that as "absent".
  Future<dynamic> getSetting(String key) async {
    final response = await _get(Uri.parse('$_baseUrl/settings/$key'));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load setting $key');
  }

  Future<void> putSetting(String key, dynamic value) async {
    final response = await _put(
      Uri.parse('$_baseUrl/settings/$key'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode(value),
    );
    if (response.statusCode != 200) {
      throw Exception(
          'Failed to save setting $key (${response.statusCode})');
    }
  }
}
