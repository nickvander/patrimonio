import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_service.dart';

class AuthUser {
  final String id;
  final String username;
  final String? email;
  final DateTime? lastLoginAt;
  final bool totpEnabled;

  AuthUser({
    required this.id,
    required this.username,
    this.email,
    this.lastLoginAt,
    required this.totpEnabled,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as String,
        username: json['username'] as String,
        email: json['email'] as String?,
        lastLoginAt: json['last_login_at'] == null
            ? null
            : DateTime.tryParse(json['last_login_at'] as String),
        totpEnabled: json['totp_enabled'] as bool? ?? false,
      );
}

enum AuthPhase { unknown, needsBootstrap, signedOut, signedIn }

class AuthState {
  final AuthPhase phase;
  final AuthUser? user;
  const AuthState(this.phase, [this.user]);
}

/// Thin wrapper around the auth endpoints. Holds a single source of
/// truth for whether the user is signed in, and broadcasts changes so
/// the gate widget can rebuild.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final ApiService _api = ApiService();
  final StreamController<AuthState> _controller =
      StreamController<AuthState>.broadcast();
  AuthState _current = const AuthState(AuthPhase.unknown);

  AuthState get current => _current;
  Stream<AuthState> get stream => _controller.stream;

  void _emit(AuthState s) {
    _current = s;
    _controller.add(s);
  }

  Future<AuthState> refreshStatus() async {
    try {
      final res = await _api.authStatus();
      if (res['needs_bootstrap'] == true) {
        _emit(const AuthState(AuthPhase.needsBootstrap));
      } else if (res['authenticated'] == true && res['user'] != null) {
        _emit(AuthState(
          AuthPhase.signedIn,
          AuthUser.fromJson(res['user'] as Map<String, dynamic>),
        ));
      } else {
        _emit(const AuthState(AuthPhase.signedOut));
      }
    } catch (_) {
      _emit(const AuthState(AuthPhase.signedOut));
    }
    return _current;
  }

  Future<void> login(String username, String password) async {
    final user = await _api.login(username, password);
    _emit(AuthState(AuthPhase.signedIn, user));
  }

  Future<void> bootstrap({
    required String username,
    String? email,
    required String password,
  }) async {
    final user = await _api.bootstrap(
      username: username,
      email: email,
      password: password,
    );
    _emit(AuthState(AuthPhase.signedIn, user));
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } on http.ClientException catch (_) {
      // Network failure on logout still drops local state below.
    } catch (_) {
      // Server-side revoke best-effort; clear client state regardless.
    }
    _emit(const AuthState(AuthPhase.signedOut));
  }

  /// Called by ApiService when any API call returns 401, so the rest
  /// of the app gets pushed back to the login screen without waiting
  /// for a manual refresh.
  void handleUnauthorized() {
    if (_current.phase == AuthPhase.signedIn) {
      _emit(const AuthState(AuthPhase.signedOut));
    }
  }
}

/// Decode a JSON response body into a Map. Used by ApiService and the
/// auth screens; kept here so all auth-related parsing lives together.
Map<String, dynamic> decodeJson(String body) =>
    json.decode(body) as Map<String, dynamic>;
