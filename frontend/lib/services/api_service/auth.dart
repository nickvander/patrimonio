part of '../api_service.dart';

/// Auth endpoints: login/TOTP/bootstrap/registration, invites,
/// recovery codes, active sessions, logout, and password change.
///
/// One of the five domain mixins split out of the ApiService
/// god-file — method bodies are byte-identical moves. See
/// `_ApiServiceBase` in api_service.dart for why these are mixins
/// (virtual dispatch for the test fakes that `extends ApiService`)
/// and not extensions.
mixin _AuthApi on _ApiServiceBase {
  // ----- auth -----

  Future<Map<String, dynamic>> authStatus() async {
    final res = await _client.get(Uri.parse('$_baseUrl/auth/status'));
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception(
      _t(
        'Failed to load auth status (${res.statusCode})',
        'No se pudo cargar el estado de autenticación (${res.statusCode})',
      ),
    );
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
    throw _errorFromBody(
      res,
      fallback: _t('Login failed', 'No se pudo iniciar sesión'),
    );
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
    throw _errorFromBody(
      res,
      fallback: _t(
        'TOTP verification failed',
        'No se pudo verificar el código TOTP',
      ),
    );
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
    throw _errorFromBody(
      res,
      fallback: _t('Bootstrap failed', 'No se pudo crear la cuenta inicial'),
    );
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
    throw _errorFromBody(
      res,
      fallback: _t('Registration failed', 'No se pudo completar el registro'),
    );
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
        'expires_in_hours': ?expiresInHours,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        // 'owner' or 'read_only'. Omitted → backend defaults to 'owner',
        // preserving the historical invite contract.
        'role': ?role,
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
    throw _errorFromBody(
      res,
      fallback: _t('Failed to mint invite', 'No se pudo generar la invitación'),
    );
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
    throw _errorFromBody(
      res,
      fallback: _t(
        'Failed to list invites',
        'No se pudieron cargar las invitaciones',
      ),
    );
  }

  Future<void> revokeInvite(String id) async {
    final res = await _client.delete(
      Uri.parse('$_baseUrl/auth/invites/$id'),
      headers: _csrfHeader,
    );
    _maybeUnauthorized(res);
    if (res.statusCode != 204) {
      throw _errorFromBody(
        res,
        fallback: _t(
          'Failed to revoke invite',
          'No se pudo revocar la invitación',
        ),
      );
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
      throw _errorFromBody(
        res,
        fallback: _t(
          'Password reset failed',
          'No se pudo restablecer la contraseña',
        ),
      );
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
    throw _errorFromBody(
      res,
      fallback: _t('Regenerate failed', 'No se pudieron regenerar los códigos'),
    );
  }

  Future<int> recoveryCodesCount() async {
    final res = await _get(Uri.parse('$_baseUrl/auth/recovery-codes/count'));
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      return (body['unused'] as num).toInt();
    }
    throw _errorFromBody(
      res,
      fallback: _t('Count failed', 'No se pudo obtener el conteo de códigos'),
    );
  }

  Future<({String secretBase32, String provisioningUri})>
  beginTotpEnroll() async {
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
    throw _errorFromBody(
      res,
      fallback: _t(
        'TOTP enroll failed',
        'No se pudo iniciar el registro de TOTP',
      ),
    );
  }

  Future<void> confirmTotpEnroll(String code) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/totp/confirm'),
      headers: _withCsrf({'Content-Type': 'application/json'}),
      body: json.encode({'code': code}),
    );
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(
        res,
        fallback: _t('TOTP confirm failed', 'No se pudo confirmar el TOTP'),
      );
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
      throw _errorFromBody(
        res,
        fallback: _t('Disable TOTP failed', 'No se pudo desactivar el TOTP'),
      );
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
    throw _errorFromBody(
      res,
      fallback: _t(
        'Failed to load sessions',
        'No se pudieron cargar las sesiones',
      ),
    );
  }

  Future<void> revokeSession(String sessionId) async {
    final res = await _delete(Uri.parse('$_baseUrl/auth/sessions/$sessionId'));
    if (res.statusCode != 204) {
      _maybeUnauthorized(res);
      throw _errorFromBody(
        res,
        fallback: _t(
          'Failed to revoke session',
          'No se pudo revocar la sesión',
        ),
      );
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
    throw _errorFromBody(
      res,
      fallback: _t(
        'Failed to revoke other sessions',
        'No se pudieron revocar las demás sesiones',
      ),
    );
  }

  Future<void> logout() async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/auth/logout'),
      headers: _csrfHeader,
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw _errorFromBody(
        res,
        fallback: _t('Logout failed', 'No se pudo cerrar sesión'),
      );
    }
  }

  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
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
      throw _errorFromBody(
        res,
        fallback: _t(
          'Password change failed',
          'No se pudo cambiar la contraseña',
        ),
      );
    }
  }
}
