// Native passkey implementation (Android) + inert Dart-VM/test fallback.
//
// Android's Credential Manager speaks the SAME WebAuthn JSON the backend
// (webauthn-rs) emits and consumes, so unlike the web impl there is no
// base64url<->ArrayBuffer bridging here: the server's `options.publicKey`
// object goes over the "patrimonio/passkeys" MethodChannel as a JSON string
// verbatim, and the authenticator's response JSON comes back the same way
// (see android/.../MainActivity.kt). The HTTP flow — endpoints, request
// bodies, error decoding — deliberately mirrors passkeys_web.dart 1:1.
//
// This file also compiles on the Dart test VM (flutter test) and on
// desktop, where there is no platform channel: [isAvailable] is false
// there (Platform.isAndroid gate), every ceremony throws a clean
// [PasskeyException], and nothing touches the channel at import time —
// that keeps widget tests isolated exactly like the old stub did.
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../utils/app_locale.dart';
import 'api_platform.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'passkeys_types.dart';

/// Pick the English or es-MX variant of a user-facing message based on the
/// app's active locale. The passkey service has no BuildContext, so it can't
/// use AppLocalizations — this reads the web-free locale notifier instead.
String _t(String en, String es) =>
    localeNotifier.value?.languageCode == 'es' ? es : en;

/// Channel into MainActivity.kt. Methods: `isAvailable`, `create`
/// (registration), `getCredential` (assertion) — all JSON-string pass-through.
const MethodChannel _channel = MethodChannel('patrimonio/passkeys');

class PasskeyService {
  PasskeyService._();
  static final PasskeyService instance = PasskeyService._();

  final ApiService _api = ApiService();
  // Same client factory as the web impl: on native this is the
  // cookie-persisting dart:io client sharing the process-wide jar with
  // ApiService, so the session cookie and CF-Access headers ride along.
  static final http.Client _client = createApiClient();

  String get _baseUrl => '${_api.baseUrl}/auth/passkeys';

  /// Native passkeys are Android-only (Credential Manager). Desktop and the
  /// test VM stay false so the passkey UI is hidden there, same as the old
  /// stub. Kept synchronous to match the web impl's surface; sub-API-28
  /// devices slip through this gate and get a clean ceremony error instead.
  bool get isAvailable => Platform.isAndroid;

  PasskeyException _unavailable() => PasskeyException(
    _t(
      'Passkeys aren\'t available on this device. Use your password to '
          'sign in.',
      'Las claves de acceso no están disponibles en este dispositivo. Usa '
          'tu contraseña para acceder.',
    ),
  );

  // ---------------------------------------------------------------------------
  // Registration ceremony (authenticated user adds a passkey).
  // ---------------------------------------------------------------------------

  /// Enrol a new passkey. [hardwareKeyOnly] forces a roaming (USB/NFC)
  /// security key — same option mutations as the web impl (attachment,
  /// extensions, excludeCredentials); see passkeys_web.dart for the full
  /// rationale on each.
  Future<PasskeySummary> registerNewPasskey({
    String? nickname,
    bool hardwareKeyOnly = false,
  }) async {
    if (!isAvailable) throw _unavailable();

    // 1. Ask the server for the challenge + options.
    final startRes = await _client.post(
      Uri.parse('$_baseUrl/register/start'),
      headers: const {
        'Content-Type': 'application/json',
        'X-Requested-With': 'fetch',
      },
    );
    if (startRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(
          startRes.body,
          _t(
            'Could not start passkey registration.',
            'No se pudo iniciar el registro de la clave de acceso.',
          ),
        ),
      );
    }
    final startJson = jsonDecode(startRes.body) as Map<String, dynamic>;
    final nonce = startJson['nonce'] as String;
    final options = startJson['options'] as Map<String, dynamic>;
    final publicKeyOpts = Map<String, dynamic>.from(
      options['publicKey'] as Map<String, dynamic>,
    );

    if (hardwareKeyOnly) {
      // Mirror of the web impl's security-key path: force cross-platform
      // attachment, strip the credProtect extension a roaming key can't
      // satisfy, and drop excludeCredentials so an already-synced platform
      // passkey doesn't pre-reject the ceremony before the physical key is
      // tried. (Full rationale in passkeys_web.dart.)
      final sel = Map<String, dynamic>.from(
        (publicKeyOpts['authenticatorSelection'] as Map?) ?? const {},
      );
      sel['authenticatorAttachment'] = 'cross-platform';
      publicKeyOpts['authenticatorSelection'] = sel;
      publicKeyOpts['extensions'] = <String, dynamic>{};
      publicKeyOpts['excludeCredentials'] = <Map<String, dynamic>>[];
    }

    // 2. Hand the options to Credential Manager; Android shows the
    //    passkey sheet (Google Password Manager / security key).
    final String? responseJson;
    try {
      responseJson = await _channel.invokeMethod<String>('create', {
        'requestJson': jsonEncode(publicKeyOpts),
      });
    } on PlatformException catch (e) {
      throw mapNativeCredentialError(e, registering: true);
    }
    if (responseJson == null) {
      throw PasskeyException(
        _t(
          'Passkey enrolment was cancelled.',
          'Se canceló el registro de la clave de acceso.',
        ),
      );
    }
    final credJson = jsonDecode(responseJson) as Map<String, dynamic>;
    final transports = extractTransports(credJson);

    // 3. Send the result back. Same body shape as the web impl: transports
    //    ride as their own top-level field (non-standard on
    //    RegisterPublicKeyCredential — webauthn-rs would choke on unknown
    //    enum values inside response.transports), and the attachment hint
    //    is mirrored at the outer level for the DB row.
    final finishRes = await _client.post(
      Uri.parse('$_baseUrl/register/finish'),
      headers: const {
        'Content-Type': 'application/json',
        'X-Requested-With': 'fetch',
      },
      body: jsonEncode({
        'nonce': nonce,
        'credential': credJson,
        if (nickname != null && nickname.trim().isNotEmpty)
          'nickname': nickname.trim(),
        if (credJson['authenticatorAttachment'] != null)
          'authenticator_attachment': credJson['authenticatorAttachment'],
        if (transports != null) 'transports': transports,
      }),
    );
    if (finishRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(
          finishRes.body,
          _t(
            'Could not save the new passkey.',
            'No se pudo guardar la nueva clave de acceso.',
          ),
        ),
      );
    }
    return PasskeySummary.fromJson(
      jsonDecode(finishRes.body) as Map<String, dynamic>,
    );
  }

  // ---------------------------------------------------------------------------
  // Authentication ceremony (unauthenticated user signs in with a passkey).
  // ---------------------------------------------------------------------------

  Future<AuthUser> signInWithPasskey({required String username}) async {
    if (!isAvailable) throw _unavailable();
    if (username.trim().isEmpty) {
      throw PasskeyException(
        _t(
          'Enter your username first.',
          'Primero ingresa tu nombre de usuario.',
        ),
      );
    }

    final startRes = await _client.post(
      Uri.parse('$_baseUrl/login/start'),
      headers: const {
        'Content-Type': 'application/json',
        'X-Requested-With': 'fetch',
      },
      body: jsonEncode({'username': username.trim()}),
    );
    if (startRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(
          startRes.body,
          _t(
            'Could not start passkey sign-in.',
            'No se pudo iniciar el acceso con clave de acceso.',
          ),
        ),
      );
    }
    final startJson = jsonDecode(startRes.body) as Map<String, dynamic>;
    final nonce = startJson['nonce'] as String;
    final options = startJson['options'] as Map<String, dynamic>;

    final credJson = await _assert(
      options['publicKey'] as Map<String, dynamic>,
    );

    final finishRes = await _client.post(
      Uri.parse('$_baseUrl/login/finish'),
      headers: const {
        'Content-Type': 'application/json',
        'X-Requested-With': 'fetch',
      },
      body: jsonEncode({'nonce': nonce, 'credential': credJson}),
    );
    if (finishRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(
          finishRes.body,
          _t('Passkey sign-in failed.', 'Falló el acceso con clave de acceso.'),
        ),
      );
    }
    final body = jsonDecode(finishRes.body) as Map<String, dynamic>;
    return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------------------
  // Step-up assertion + set-password (same contract as the web impl:
  // reauth returns credential+nonce WITHOUT a finish call).
  // ---------------------------------------------------------------------------

  Future<({Map<String, dynamic> credential, String nonce})>
  reauthWithPasskey() async {
    if (!isAvailable) throw _unavailable();

    final startRes = await _client.post(
      Uri.parse('${_api.baseUrl}/auth/reauth/passkey/start'),
      headers: const {
        'Content-Type': 'application/json',
        'X-Requested-With': 'fetch',
      },
    );
    if (startRes.statusCode == 401) {
      throw UnauthorizedException();
    }
    if (startRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(
          startRes.body,
          _t(
            'Could not start passkey verification.',
            'No se pudo iniciar la verificación con clave de acceso.',
          ),
        ),
      );
    }
    final startJson = jsonDecode(startRes.body) as Map<String, dynamic>;
    final nonce = startJson['nonce'] as String;
    final options = startJson['options'] as Map<String, dynamic>;

    final credJson = await _assert(
      options['publicKey'] as Map<String, dynamic>,
    );
    return (credential: credJson, nonce: nonce);
  }

  Future<void> setPasswordWithPasskey({
    required Map<String, dynamic> credential,
    required String nonce,
    required String newPassword,
  }) async {
    final res = await _client.post(
      Uri.parse('${_api.baseUrl}/auth/set-password'),
      headers: const {
        'Content-Type': 'application/json',
        'X-Requested-With': 'fetch',
      },
      body: jsonEncode({
        'nonce': nonce,
        'credential': credential,
        'new_password': newPassword,
      }),
    );
    if (res.statusCode == 204) return;
    throw PasskeyException(
      _decodeError(
        res.body,
        _t(
          'Could not set the new password.',
          'No se pudo establecer la nueva contraseña.',
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // List / remove (authenticated) — pure HTTP, identical to web.
  // ---------------------------------------------------------------------------

  Future<List<PasskeySummary>> list() async {
    // Non-Android native (desktop/test VM) has no passkeys: return empty so
    // the Security screen shows the "unavailable" card, same as the old stub.
    if (!isAvailable) return const [];
    final res = await _client.get(Uri.parse(_baseUrl));
    if (res.statusCode == 401) {
      throw UnauthorizedException();
    }
    if (res.statusCode != 200) {
      throw PasskeyException(
        _decodeError(
          res.body,
          _t(
            'Could not load passkeys.',
            'No se pudieron cargar las claves de acceso.',
          ),
        ),
      );
    }
    final raw = jsonDecode(res.body) as List<dynamic>;
    return raw
        .map((e) => PasskeySummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> remove(String id) async {
    final res = await _client.delete(
      Uri.parse('$_baseUrl/$id'),
      headers: const {'X-Requested-With': 'fetch'},
    );
    if (res.statusCode == 401) {
      throw UnauthorizedException();
    }
    if (res.statusCode != 204) {
      throw PasskeyException(
        _decodeError(
          res.body,
          _t(
            'Could not remove the passkey.',
            'No se pudo eliminar la clave de acceso.',
          ),
        ),
      );
    }
  }

  /// Run the native assertion ceremony against `publicKey` request options
  /// and return the credential JSON ready for a finish/set-password body.
  Future<Map<String, dynamic>> _assert(Map<String, dynamic> publicKey) async {
    final String? responseJson;
    try {
      responseJson = await _channel.invokeMethod<String>('getCredential', {
        'requestJson': jsonEncode(publicKey),
      });
    } on PlatformException catch (e) {
      throw mapNativeCredentialError(e, registering: false);
    }
    if (responseJson == null) {
      throw PasskeyException(
        _t(
          'Passkey sign-in was cancelled.',
          'Se canceló el acceso con clave de acceso.',
        ),
      );
    }
    return jsonDecode(responseJson) as Map<String, dynamic>;
  }
}

/// Pull `transports` OUT of a GMS registration response, wherever it landed.
/// The WebAuthn JSON spec puts it at `response.transports`; the web impl's
/// encoder used to lift it to the top level — handle both so the finish body
/// always carries it as its own field and the credential object never does
/// (webauthn-rs' response.transports enum rejects unknown values like
/// "hybrid" on some versions, so leaving it embedded risks a 422 on the
/// whole registration).
@visibleForTesting
List<String>? extractTransports(Map<String, dynamic> credJson) {
  List<String>? found;
  final response = credJson['response'];
  if (response is Map<String, dynamic>) {
    final t = response.remove('transports');
    if (t is List) found = t.cast<String>();
  }
  final top = credJson.remove('transports');
  if (found == null && top is List) found = top.cast<String>();
  return (found == null || found.isEmpty) ? null : found;
}

/// Map a Credential Manager [PlatformException] to an actionable
/// [PasskeyException]. MainActivity surfaces androidx's `e.type` as the
/// error code — for DOM exceptions that embeds the WebAuthn error name
/// (INVALID_STATE_ERROR, NOT_ALLOWED_ERROR, ...), so this mirrors the web
/// impl's DOMException-name matching, plus the androidx-specific
/// cancellation/no-credential cases that have no web equivalent.
@visibleForTesting
PasskeyException mapNativeCredentialError(
  PlatformException e, {
  required bool registering,
}) {
  final probe = '${e.code} ${e.message ?? ''}'.toUpperCase();
  final verb = registering
      ? _t('enrolment', 'registro')
      : _t('sign-in', 'acceso');
  if (probe.contains('CANCEL')) {
    // TYPE_USER_CANCELED / CreateCredentialCancellationException et al.
    return PasskeyException(
      _t(
        'Passkey $verb was cancelled or timed out. Please try again.',
        'El $verb con clave de acceso se canceló o expiró. Inténtalo de '
            'nuevo.',
      ),
    );
  }
  if (probe.contains('NO_CREDENTIAL')) {
    return PasskeyException(
      _t(
        'No matching passkey is available on this phone. Register one from '
            'Security first, or use your password.',
        'No hay una clave de acceso disponible en este teléfono. Primero '
            'registra una desde Seguridad, o usa tu contraseña.',
      ),
    );
  }
  if (probe.contains('INVALID_STATE')) {
    return PasskeyException(
      registering
          ? _t(
              'A passkey for this account already exists on this device. To '
                  'replace it, remove it on the Security screen first.',
              'Ya existe una clave de acceso para esta cuenta en este '
                  'dispositivo. Para reemplazarla, primero elimínala en la '
                  'pantalla de Seguridad.',
            )
          : _t(
              'This passkey isn\'t recognised for this account.',
              'Esta clave de acceso no se reconoce para esta cuenta.',
            ),
    );
  }
  if (probe.contains('NOT_ALLOWED') || probe.contains('ABORT')) {
    return PasskeyException(
      _t(
        'Passkey $verb was cancelled or timed out. Please try again.',
        'El $verb con clave de acceso se canceló o expiró. Inténtalo de '
            'nuevo.',
      ),
    );
  }
  if (probe.contains('NOT_SUPPORTED') || probe.contains('UNSUPPORTED')) {
    return PasskeyException(
      _t(
        'This authenticator isn\'t supported. Try a different device or '
            'security key.',
        'Este autenticador no es compatible. Prueba con otro dispositivo o '
            'llave de seguridad.',
      ),
    );
  }
  if (probe.contains('SECURITY')) {
    // On native this usually means Digital Asset Links verification failed:
    // the server's /.well-known/assetlinks.json is missing, unreachable
    // (Cloudflare Access without the Bypass policy!), or lists a different
    // signing cert than the installed APK's.
    return PasskeyException(
      _t(
        'Passkey $verb was blocked: this app isn\'t authorized for the '
            'server\'s domain. Check the server\'s assetlinks.json setup.',
        'El $verb con clave de acceso se bloqueó: esta app no está '
            'autorizada para el dominio del servidor. Revisa la configuración '
            'de assetlinks.json del servidor.',
      ),
    );
  }
  final detail = e.message?.isNotEmpty == true ? e.message! : e.code;
  return PasskeyException(
    _t(
      'Passkey $verb failed: $detail',
      'El $verb con clave de acceso falló: $detail',
    ),
  );
}

String _decodeError(String body, String fallback) {
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final msg = json['error'];
    if (msg is String && msg.isNotEmpty) return msg;
  } catch (_) {}
  return fallback;
}
