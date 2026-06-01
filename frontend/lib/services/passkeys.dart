import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http/browser_client.dart';

import '../utils/app_locale.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// Pick the English or es-MX variant of a user-facing message based on the
/// app's active locale. The passkey service has no BuildContext, so it can't
/// use AppLocalizations — this reads the web-free locale notifier instead.
String _t(String en, String es) =>
    localeNotifier.value?.languageCode == 'es' ? es : en;

/// One row from `GET /api/auth/passkeys`.
class PasskeySummary {
  final String id;
  final String? nickname;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  /// "platform" (phone / laptop biometric) or "cross-platform" (USB /
  /// NFC hardware key). Null if the browser declined to say.
  final String? authenticatorAttachment;

  PasskeySummary({
    required this.id,
    this.nickname,
    required this.createdAt,
    this.lastUsedAt,
    this.authenticatorAttachment,
  });

  factory PasskeySummary.fromJson(Map<String, dynamic> json) => PasskeySummary(
        id: json['id'] as String,
        nickname: json['nickname'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        lastUsedAt: json['last_used_at'] == null
            ? null
            : DateTime.parse(json['last_used_at'] as String),
        authenticatorAttachment: json['authenticator_attachment'] as String?,
      );

  /// True when this passkey lives on a roaming authenticator (a USB /
  /// NFC security key plugged into whichever machine the user is on),
  /// rather than on the device itself.
  bool get isHardwareKey => authenticatorAttachment == 'cross-platform';
}

/// Thrown when the browser doesn't expose `navigator.credentials` or
/// the user cancels the platform prompt. We catch and surface this as
/// a user-friendly snackbar at the call site.
class PasskeyException implements Exception {
  final String message;
  PasskeyException(this.message);
  @override
  String toString() => message;
}

/// Thin client over the four `/api/auth/passkeys/*` endpoints plus the
/// JS-interop dance with `navigator.credentials.create` / `.get`.
///
/// The WebAuthn JS surface speaks ArrayBuffers for the binary fields
/// (challenge, raw credential id, attestation/assertion blobs); the
/// HTTP API speaks base64url strings. This file is mostly that bridge.
class PasskeyService {
  PasskeyService._();
  static final PasskeyService instance = PasskeyService._();

  final ApiService _api = ApiService();
  // BrowserClient with withCredentials=true is required so the session
  // cookie is sent on cross-origin XHRs during local dev (frontend on
  // :3000, API on :8080). Identical in same-origin prod; harmless. The
  // password login path uses the same shape — match it so a passkey
  // user gets the same Set-Cookie handling.
  static final BrowserClient _client = BrowserClient()..withCredentials = true;

  String get _baseUrl => '${_api.baseUrl}/auth/passkeys';

  /// True when the browser exposes the WebAuthn API. The auth gate and
  /// security screen use this to hide the passkey UI on browsers (or
  /// embedded webviews) that can't speak FIDO2.
  bool get isAvailable {
    try {
      // navigator.credentials is itself a JSObject; the create / get
      // methods only exist on the modern CredentialsContainer that
      // supports PublicKeyCredential. We just verify the global type
      // exists — that's the spec-recommended sniff.
      return globalContext.has('PublicKeyCredential') &&
          globalContext.has('navigator');
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Registration ceremony (authenticated user adds a passkey).
  // ---------------------------------------------------------------------------

  /// Enrol a new passkey. When [hardwareKeyOnly] is true we constrain the
  /// ceremony to a roaming (cross-platform) authenticator — a USB / NFC
  /// security key like a YubiKey or Titan. This is the escape hatch for the
  /// "a synced platform passkey provider keeps intercepting and throwing
  /// InvalidStateError" problem: forcing cross-platform attachment makes the
  /// browser prompt for the physical key directly instead of offering the
  /// already-enrolled synced passkey.
  Future<PasskeySummary> registerNewPasskey({
    String? nickname,
    bool hardwareKeyOnly = false,
  }) async {
    if (!isAvailable) {
      throw PasskeyException(_t(
        'This browser doesn\'t support passkeys. Try Chrome/Safari/Edge on a recent OS.',
        'Este navegador no admite claves de acceso. Prueba con Chrome/Safari/Edge en un sistema reciente.',
      ));
    }

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
        _decodeError(startRes.body, _t('Could not start passkey registration.',
            'No se pudo iniciar el registro de la clave de acceso.')),
      );
    }
    final startJson = jsonDecode(startRes.body) as Map<String, dynamic>;
    final nonce = startJson['nonce'] as String;
    final options = startJson['options'] as Map<String, dynamic>;
    final publicKeyOpts =
        Map<String, dynamic>.from(options['publicKey'] as Map<String, dynamic>);

    if (hardwareKeyOnly) {
      // Force a roaming security key: the browser then prompts "insert your
      // security key" and skips the synced platform passkey provider. We only
      // override authenticatorAttachment — residentKey / userVerification are
      // left as the server's PasskeyRegistration state requires them (resident
      // + UV), so the finish step stays consistent. NOTE: webauthn-rs 0.5's
      // passkey policy mandates User Verification, so the security key must
      // have a PIN/biometric configured (a tap-only key will be rejected with
      // NotAllowedError — see the security-key registration path for the
      // relaxed-UV alternative).
      final sel = Map<String, dynamic>.from(
          (publicKeyOpts['authenticatorSelection'] as Map?) ?? const {});
      sel['authenticatorAttachment'] = 'cross-platform';
      publicKeyOpts['authenticatorSelection'] = sel;
      // Strip the credProtect extension on the security-key path. webauthn-rs
      // attaches a credentialProtectionPolicy (UV-required, enforced) that a
      // roaming key can't satisfy here — it surfaced as a generic
      // NotAllowedError (UV=required) or NotSupportedError "protection policy
      // inconsistent" (UV relaxed). Roaming 2FA keys don't need credProtect, so
      // clear extensions for this ceremony; UV stays as the server set it.
      publicKeyOpts['extensions'] = <String, dynamic>{};
      // Drop excludeCredentials on the security-key path. The user's existing
      // credential is a SYNCED platform passkey that's present on this device
      // via the password manager; with it in excludeCredentials, Chrome sees
      // it available locally and pre-rejects create() with a generic
      // NotAllowedError BEFORE the physical security key is ever tried. Safe
      // to drop here: authenticatorAttachment=cross-platform already keeps the
      // synced passkey from being re-used, and webauthn-rs validates the new
      // credential at finish regardless of exclusions (the global
      // UNIQUE(credential_id) + the 409 path still prevent a true duplicate).
      publicKeyOpts['excludeCredentials'] = <Map<String, dynamic>>[];
    }

    // 2. Hand the publicKey options to the browser. The platform shows
    //    the biometric prompt and returns a PublicKeyCredential.
    final publicKey = _coerceCreationOptions(publicKeyOpts);
    final cred = await _callCredentialsCreate(publicKey);
    final credJson = _encodeAttestationCredential(cred);
    // Lift transports OUT of the credential object before sending — it's a
    // non-standard field on RegisterPublicKeyCredential and rides as its own
    // top-level request field instead.
    final transports = credJson.remove('transports');

    // 3. Send the result + the nickname + attachment hint back to the
    //    server. The attachment lives inside credJson but webauthn-rs
    //    deserialises only spec-defined fields, so we mirror it at the
    //    outer level too — that's what the DB row reads.
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
        _decodeError(finishRes.body, _t('Could not save the new passkey.',
            'No se pudo guardar la nueva clave de acceso.')),
      );
    }
    return PasskeySummary.fromJson(
      jsonDecode(finishRes.body) as Map<String, dynamic>,
    );
  }

  // ---------------------------------------------------------------------------
  // Authentication ceremony (unauthenticated user signs in with a passkey).
  // ---------------------------------------------------------------------------

  /// Returns the signed-in [AuthUser]. The session cookie is set as a
  /// side-effect by the server's Set-Cookie header. `username` is the
  /// value typed in the login form — the backend uses it to scope the
  /// assertion challenge to that account's registered passkeys.
  Future<AuthUser> signInWithPasskey({required String username}) async {
    if (!isAvailable) {
      throw PasskeyException(_t(
        'This browser doesn\'t support passkeys. Try Chrome/Safari/Edge on a recent OS.',
        'Este navegador no admite claves de acceso. Prueba con Chrome/Safari/Edge en un sistema reciente.',
      ));
    }
    if (username.trim().isEmpty) {
      throw PasskeyException(_t('Enter your username first.',
          'Primero ingresa tu nombre de usuario.'));
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
        _decodeError(startRes.body, _t('Could not start passkey sign-in.',
            'No se pudo iniciar el acceso con clave de acceso.')),
      );
    }
    final startJson = jsonDecode(startRes.body) as Map<String, dynamic>;
    final nonce = startJson['nonce'] as String;
    final options = startJson['options'] as Map<String, dynamic>;

    final publicKey =
        _coerceRequestOptions(options['publicKey'] as Map<String, dynamic>);
    final assertion = await _callCredentialsGet(publicKey);
    final credJson = _encodeAssertionCredential(assertion);

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
        _decodeError(finishRes.body, _t('Passkey sign-in failed.',
            'Falló el acceso con clave de acceso.')),
      );
    }
    final body = jsonDecode(finishRes.body) as Map<String, dynamic>;
    return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------------------
  // List / remove (authenticated).
  // ---------------------------------------------------------------------------

  Future<List<PasskeySummary>> list() async {
    final res = await _client.get(Uri.parse(_baseUrl));
    if (res.statusCode == 401) {
      throw UnauthorizedException();
    }
    if (res.statusCode != 200) {
      throw PasskeyException(
        _decodeError(res.body, _t('Could not load passkeys.',
            'No se pudieron cargar las claves de acceso.')),
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
        _decodeError(res.body, _t('Could not remove the passkey.',
            'No se pudo eliminar la clave de acceso.')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// JS interop helpers.
//
// The server sends WebAuthn binary fields as base64url-no-pad strings.
// The browser's navigator.credentials API wants ArrayBuffers. Walk the
// options tree, replace strings with the right ArrayBuffer in each
// known spot, and hand the result to the platform.
//
// On the way back, the browser hands us a `PublicKeyCredential` whose
// `rawId` and `response.*` fields are ArrayBuffers. We base64url-encode
// each one before POSTing to /finish.
// ---------------------------------------------------------------------------

Future<JSObject> _callCredentialsCreate(JSObject publicKey) async {
  final wrap = _emptyJsObject();
  wrap['publicKey'] = publicKey;
  final navigator = globalContext['navigator'] as JSObject;
  final credentials = navigator['credentials'] as JSObject;
  final JSObject? result;
  try {
    final promise =
        credentials.callMethod<JSPromise<JSAny?>>('create'.toJS, wrap);
    result = (await promise.toDart) as JSObject?;
  } catch (e) {
    // The browser rejects the create() promise with a DOMException for the
    // common failure modes — most notably InvalidStateError when the
    // authenticator is ALREADY enrolled (it sees its own credential in
    // excludeCredentials). Without this mapping the raw JS error reached
    // the snackbar as a cryptic string; map it to something actionable.
    throw _mapCredentialError(e, registering: true);
  }
  if (result == null) {
    throw PasskeyException(_t('Passkey enrolment was cancelled.',
        'Se canceló el registro de la clave de acceso.'));
  }
  return result;
}

Future<JSObject> _callCredentialsGet(JSObject publicKey) async {
  final wrap = _emptyJsObject();
  wrap['publicKey'] = publicKey;
  final navigator = globalContext['navigator'] as JSObject;
  final credentials = navigator['credentials'] as JSObject;
  final JSObject? result;
  try {
    final promise =
        credentials.callMethod<JSPromise<JSAny?>>('get'.toJS, wrap);
    result = (await promise.toDart) as JSObject?;
  } catch (e) {
    throw _mapCredentialError(e, registering: false);
  }
  if (result == null) {
    throw PasskeyException(_t('Passkey sign-in was cancelled.',
        'Se canceló el acceso con clave de acceso.'));
  }
  return result;
}

/// Turn a WebAuthn `DOMException` (thrown by navigator.credentials
/// create/get) into a clear, actionable [PasskeyException]. We read the
/// exception's `name`/`message` off the JS object when we can, and also
/// string-match as a fallback since the boxed-error type varies across
/// Dart web backends.
PasskeyException _mapCredentialError(Object e, {required bool registering}) {
  if (e is PasskeyException) return e;
  String name = '';
  String message = '';
  try {
    final obj = e as JSObject;
    final n = obj['name'];
    if (n != null) name = (n as JSString).toDart;
    final m = obj['message'];
    if (m != null) message = (m as JSString).toDart;
  } catch (_) {
    // Not a JS object (or property read failed) — fall back to toString.
  }
  final probe = '$name $message ${e.toString()}';
  final verb = registering
      ? _t('enrolment', 'registro')
      : _t('sign-in', 'acceso');
  if (probe.contains('InvalidStateError')) {
    return PasskeyException(registering
        ? _t(
            'A passkey for this account already exists on the authenticator you '
            'used. If you\'re adding a DIFFERENT security key, your browser is '
            'likely offering a saved/synced passkey instead of the new key — '
            'in the prompt choose "Use a different device" (or insert the key '
            'and pick the security-key / USB option). To replace the existing '
            'passkey, remove it on this screen first.',
            'Ya existe una clave de acceso para esta cuenta en el autenticador '
            'que usaste. Si estás agregando una llave de seguridad DISTINTA, tu '
            'navegador probablemente esté ofreciendo una clave guardada o '
            'sincronizada en lugar de la nueva — en el aviso elige "Usar otro '
            'dispositivo" (o inserta la llave y elige la opción de llave de '
            'seguridad / USB). Para reemplazar la clave existente, primero '
            'elimínala en esta pantalla.')
        : _t('This passkey isn\'t recognised for this account.',
            'Esta clave de acceso no se reconoce para esta cuenta.'));
  }
  if (probe.contains('NotAllowedError') || probe.contains('AbortError')) {
    return PasskeyException(_t(
        'Passkey $verb was cancelled or timed out. Please try again.',
        'El $verb con clave de acceso se canceló o expiró. Inténtalo de nuevo.'));
  }
  if (probe.contains('NotSupportedError')) {
    return PasskeyException(_t(
        'This authenticator isn\'t supported. Try a different device or '
        'security key.',
        'Este autenticador no es compatible. Prueba con otro dispositivo o '
        'llave de seguridad.'));
  }
  if (probe.contains('SecurityError')) {
    return PasskeyException(_t(
        'Passkey $verb was blocked for security reasons (the site origin '
        'or domain didn\'t match). Make sure you\'re on the right URL.',
        'El $verb con clave de acceso se bloqueó por razones de seguridad (el '
        'origen o dominio del sitio no coincidió). Asegúrate de estar en la URL '
        'correcta.'));
  }
  if (probe.contains('ConstraintError')) {
    return PasskeyException(_t(
        'This authenticator can\'t satisfy the required settings (e.g. it '
        'needs a PIN or biometric). Try a different one.',
        'Este autenticador no cumple con los ajustes requeridos (p. ej. '
        'necesita un PIN o biometría). Prueba con otro.'));
  }
  final detail = message.isNotEmpty ? message : e.toString();
  return PasskeyException(_t('Passkey $verb failed: $detail',
      'El $verb con clave de acceso falló: $detail'));
}

// ----- decoding server → JS (base64url strings → ArrayBuffer) -----

JSObject _coerceCreationOptions(Map<String, dynamic> opts) {
  final out = _emptyJsObject();
  for (final entry in opts.entries) {
    final k = entry.key;
    final v = entry.value;
    switch (k) {
      case 'challenge':
        out[k] = _base64UrlToBuffer(v as String);
      case 'user':
        final u = Map<String, dynamic>.from(v as Map);
        final userObj = _emptyJsObject();
        userObj['id'] = _base64UrlToBuffer(u['id'] as String);
        userObj['name'] = (u['name'] as String).toJS;
        userObj['displayName'] = (u['displayName'] as String).toJS;
        out[k] = userObj;
      case 'excludeCredentials':
        final list = (v as List?)?.cast<Map<String, dynamic>>() ?? const [];
        out[k] = _credentialDescriptorsToJs(list);
      case 'rp':
        final rp = Map<String, dynamic>.from(v as Map);
        final rpObj = _emptyJsObject();
        rpObj['id'] = (rp['id'] as String).toJS;
        rpObj['name'] = (rp['name'] as String).toJS;
        out[k] = rpObj;
      default:
        final jsValue = _toJsValue(v);
        if (jsValue != null) {
          out[k] = jsValue;
        }
    }
  }
  return out;
}

JSObject _coerceRequestOptions(Map<String, dynamic> opts) {
  final out = _emptyJsObject();
  for (final entry in opts.entries) {
    final k = entry.key;
    final v = entry.value;
    switch (k) {
      case 'challenge':
        out[k] = _base64UrlToBuffer(v as String);
      case 'allowCredentials':
        final list = (v as List?)?.cast<Map<String, dynamic>>() ?? const [];
        out[k] = _credentialDescriptorsToJs(list);
      default:
        final jsValue = _toJsValue(v);
        if (jsValue != null) {
          out[k] = jsValue;
        }
    }
  }
  return out;
}

JSArray<JSObject> _credentialDescriptorsToJs(List<Map<String, dynamic>> list) {
  final array = JSArray<JSObject>.withLength(list.length);
  for (var i = 0; i < list.length; i++) {
    final desc = list[i];
    final obj = _emptyJsObject();
    obj['type'] = (desc['type'] as String).toJS;
    obj['id'] = _base64UrlToBuffer(desc['id'] as String);
    if (desc['transports'] is List) {
      obj['transports'] = _stringListToJs(
        (desc['transports'] as List).cast<String>(),
      );
    }
    array[i] = obj;
  }
  return array;
}

JSArray<JSString> _stringListToJs(List<String> values) {
  final array = JSArray<JSString>.withLength(values.length);
  for (var i = 0; i < values.length; i++) {
    array[i] = values[i].toJS;
  }
  return array;
}

JSAny? _toJsValue(dynamic v) {
  if (v == null) return null;
  if (v is String) return v.toJS;
  if (v is bool) return v.toJS;
  if (v is int) return v.toJS;
  if (v is double) return v.toJS;
  if (v is List) {
    final arr = JSArray<JSAny?>.withLength(v.length);
    for (var i = 0; i < v.length; i++) {
      arr[i] = _toJsValue(v[i]);
    }
    return arr;
  }
  if (v is Map) {
    final obj = _emptyJsObject();
    v.forEach((key, value) {
      final jv = _toJsValue(value);
      if (jv != null) obj[key.toString()] = jv;
    });
    return obj;
  }
  // Fall back to JSON round-trip for anything exotic (none expected).
  return jsonEncode(v).toJS;
}

@JS('Object')
external JSFunction _objectCtor;

JSObject _emptyJsObject() => _objectCtor.callAsConstructor<JSObject>();

// ----- encoding JS → server (ArrayBuffer → base64url strings) -----

Map<String, dynamic> _encodeAttestationCredential(JSObject cred) {
  final out = <String, dynamic>{};
  out['id'] = (cred['id'] as JSString).toDart;
  out['type'] = (cred['type'] as JSString).toDart;
  out['rawId'] = _bufferToBase64Url(cred['rawId']);
  final response = cred['response'] as JSObject;
  out['response'] = {
    'clientDataJSON': _bufferToBase64Url(response['clientDataJSON']),
    'attestationObject': _bufferToBase64Url(response['attestationObject']),
  };
  // Some browsers/authenticators decorate with `authenticatorAttachment`;
  // pass it through if present — webauthn-rs tolerates absence.
  if (cred.has('authenticatorAttachment')) {
    final attachment = cred['authenticatorAttachment'];
    if (attachment != null) {
      out['authenticatorAttachment'] = (attachment as JSString).toDart;
    }
  }
  // Transports (usb/nfc/ble/hybrid/internal) are a far more reliable signal
  // for "roaming hardware key vs on-device passkey" than the attachment
  // hint, which browsers often misreport (e.g. a YubiKey surfacing as
  // "platform"). getTransports() lives on the attestation response and isn't
  // universal, so probe defensively.
  try {
    final t = response.callMethod<JSArray<JSString>?>('getTransports'.toJS);
    if (t != null) {
      final list = t.toDart.map((s) => s.toDart).toList();
      if (list.isNotEmpty) out['transports'] = list;
    }
  } catch (_) {
    // Authenticator/browser doesn't expose getTransports — fine, the server
    // falls back to the attachment hint.
  }
  // Optional extensions block — empty object is the safe default.
  out['extensions'] = <String, dynamic>{};
  return out;
}

Map<String, dynamic> _encodeAssertionCredential(JSObject cred) {
  final out = <String, dynamic>{};
  out['id'] = (cred['id'] as JSString).toDart;
  out['type'] = (cred['type'] as JSString).toDart;
  out['rawId'] = _bufferToBase64Url(cred['rawId']);
  final response = cred['response'] as JSObject;
  out['response'] = {
    'clientDataJSON': _bufferToBase64Url(response['clientDataJSON']),
    'authenticatorData': _bufferToBase64Url(response['authenticatorData']),
    'signature': _bufferToBase64Url(response['signature']),
    if (response.has('userHandle') && response['userHandle'] != null)
      'userHandle': _bufferToBase64Url(response['userHandle']),
  };
  if (cred.has('authenticatorAttachment')) {
    final attachment = cred['authenticatorAttachment'];
    if (attachment != null) {
      out['authenticatorAttachment'] = (attachment as JSString).toDart;
    }
  }
  out['extensions'] = <String, dynamic>{};
  return out;
}

// ----- base64url <-> ArrayBuffer -----

/// Build a `Uint8Array` from raw bytes — the WebAuthn JS API accepts
/// any `BufferSource`, and `Uint8Array` is the simplest one to round-trip
/// through `dart:typed_data`'s `Uint8List`.
JSAny _base64UrlToBuffer(String s) {
  final bytes = _decodeBase64Url(s);
  return bytes.toJS;
}

String _bufferToBase64Url(JSAny? buf) {
  if (buf == null) {
    throw PasskeyException('Missing binary field in passkey response.');
  }
  // The browser may hand us either a Uint8Array or a raw ArrayBuffer.
  // Wrap the latter in a Uint8Array view to get a consistent type.
  final view = buf.isA<JSUint8Array>()
      ? buf as JSUint8Array
      : (buf as JSArrayBuffer).toDart.asUint8List().toJS;
  return _encodeBase64Url(view.toDart);
}

Uint8List _decodeBase64Url(String s) {
  // Convert URL-safe alphabet to standard, pad to a multiple of 4.
  var t = s.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64Decode(t);
}

String _encodeBase64Url(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _decodeError(String body, String fallback) {
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final msg = json['error'];
    if (msg is String && msg.isNotEmpty) return msg;
  } catch (_) {}
  return fallback;
}
