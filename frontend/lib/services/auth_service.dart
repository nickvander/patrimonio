import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_platform.dart';
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

enum AuthPhase { unknown, needsBootstrap, signedOut, awaitingTotp, signedIn }

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
      } else if (res['requires_totp'] == true) {
        // A page refresh during the two-step login flow lands here:
        // the server resolved the cookie to a pending-TOTP session.
        // Route to the challenge screen instead of dropping back to
        // login.
        _emit(const AuthState(AuthPhase.awaitingTotp));
      } else {
        _emit(const AuthState(AuthPhase.signedOut));
      }
    } catch (_) {
      _emit(const AuthState(AuthPhase.signedOut));
    }
    return _current;
  }

  /// Login result. `null` user means the server is asking us to walk
  /// the user through the TOTP step before promoting to signed-in.
  Future<LoginOutcome> login(String username, String password) async {
    final outcome = await _api.login(username, password);
    if (outcome.user != null) {
      _emit(AuthState(AuthPhase.signedIn, outcome.user));
    } else if (outcome.requiresTotp) {
      _emit(const AuthState(AuthPhase.awaitingTotp));
    }
    return outcome;
  }

  Future<void> verifyTotp(String code) async {
    final user = await _api.verifyTotp(code);
    _emit(AuthState(AuthPhase.signedIn, user));
  }

  /// Result of bootstrap — user plus the one-time recovery codes that
  /// the UI must display once and then never again.
  Future<BootstrapOutcome> bootstrap({
    required String username,
    String? email,
    required String password,
  }) async {
    final out = await _api.bootstrap(
      username: username,
      email: email,
      password: password,
    );
    _emit(AuthState(AuthPhase.signedIn, out.user));
    return out;
  }

  Future<void> recover({
    required String username,
    required String code,
    required String newPassword,
  }) async {
    await _api.recover(
      username: username,
      code: code,
      newPassword: newPassword,
    );
    // Recovery does NOT sign the user in — they have to log in fresh
    // with the new password (forces a password recall + audit row).
    _emit(const AuthState(AuthPhase.signedOut));
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } on http.ClientException catch (_) {
      // Network failure on logout still drops local state below.
    } catch (_) {
      // Server-side revoke best-effort; clear client state regardless.
    }
    // The server's removal Set-Cookie already empties the native jar when
    // the request succeeds; this also covers the network-failure path so a
    // locally "signed out" app can't silently resurrect the session (from
    // the keystore mirror) on its next launch.
    await clearPersistedSession();
    _emit(const AuthState(AuthPhase.signedOut));
  }

  /// Called by ApiService when any API call returns 401, so the rest
  /// of the app gets pushed back to the login screen without waiting
  /// for a manual refresh.
  void handleUnauthorized() {
    // The server no longer honours the session — drop the native jar and
    // its keystore mirror so the dead cookie isn't restored next launch.
    // Fire-and-forget: this callback is sync and the UI transition below
    // must not wait on storage I/O.
    unawaited(clearPersistedSession());
    if (_current.phase == AuthPhase.signedIn) {
      _emit(const AuthState(AuthPhase.signedOut));
    }
  }
}

/// Decode a JSON response body into a Map. Used by ApiService and the
/// auth screens; kept here so all auth-related parsing lives together.
Map<String, dynamic> decodeJson(String body) =>
    json.decode(body) as Map<String, dynamic>;

/// Returned from /api/auth/bootstrap — the user has been created AND
/// signed in, and the server has handed us a one-time-display batch
/// of recovery codes.
class BootstrapOutcome {
  final AuthUser user;
  final List<String> recoveryCodes;
  const BootstrapOutcome(this.user, this.recoveryCodes);
}

/// Returned from /api/auth/invites POST — the plaintext invite token
/// shown ONCE so the admin can share the URL. After this response the
/// only stored thing on the server is the SHA-256 hash.
class InviteMint {
  final String id;
  final String token;
  final String url;
  final DateTime expiresAt;
  const InviteMint({
    required this.id,
    required this.token,
    required this.url,
    required this.expiresAt,
  });
}

/// One row from /api/auth/invites GET — the metadata view that omits
/// the plaintext token (which only ever exists in the mint response).
class InviteSummary {
  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool used;
  final DateTime? usedAt;
  final String? note;
  /// 'owner' or 'read_only'. The role the redeemer inherits. Lets the
  /// Security screen flag read-only invites so the inviter can audit
  /// (and revoke) the wrong ones before someone redeems. Defaults to
  /// 'owner' for older backends that predate the roles column.
  final String role;
  const InviteSummary({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.used,
    required this.usedAt,
    required this.note,
    this.role = 'owner',
  });
  bool get isReadOnly => role == 'read_only';
  factory InviteSummary.fromJson(Map<String, dynamic> json) {
    return InviteSummary(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: DateTime.parse(json['expires_at'] as String),
      used: json['used'] as bool? ?? false,
      usedAt: (json['used_at'] as String?) == null
          ? null
          : DateTime.parse(json['used_at'] as String),
      note: json['note'] as String?,
      role: json['role'] as String? ?? 'owner',
    );
  }
}

/// One row from /api/auth/sessions — used by the Security screen's
/// "Active sessions" list.
class ActiveSession {
  final String id;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime expiresAt;
  final String? userAgent;
  final String? ipAddress;
  final bool isCurrent;
  /// True when `created_at > users.previous_login_at`. The Security
  /// screen renders these with a "New since last visit" pill so the
  /// user can spot a session they don't recognise at a glance.
  /// Never true for the current session — would be noise.
  final bool newSinceLastVisit;

  ActiveSession({
    required this.id,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    this.userAgent,
    this.ipAddress,
    required this.isCurrent,
    this.newSinceLastVisit = false,
  });

  factory ActiveSession.fromJson(Map<String, dynamic> json) => ActiveSession(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        lastSeenAt: DateTime.parse(json['last_seen_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
        userAgent: json['user_agent'] as String?,
        ipAddress: json['ip_address'] as String?,
        isCurrent: json['is_current'] as bool? ?? false,
        newSinceLastVisit: json['new_since_last_visit'] as bool? ?? false,
      );
}

/// Returned from /api/auth/login. Either the user is fully signed in
/// (`user` non-null) or they need to walk through the TOTP step.
class LoginOutcome {
  final AuthUser? user;
  final bool requiresTotp;
  const LoginOutcome.complete(AuthUser this.user) : requiresTotp = false;
  const LoginOutcome.needsTotp()
      : user = null,
        requiresTotp = true;
}
