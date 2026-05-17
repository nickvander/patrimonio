import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'auth_service.dart';

/// One row from `GET /api/auth/passkeys`.
class PasskeySummary {
  final String id;
  final String? nickname;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  PasskeySummary({
    required this.id,
    this.nickname,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory PasskeySummary.fromJson(Map<String, dynamic> json) => PasskeySummary(
        id: json['id'] as String,
        nickname: json['nickname'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        lastUsedAt: json['last_used_at'] == null
            ? null
            : DateTime.parse(json['last_used_at'] as String),
      );
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
  static final _client = _credentialedClient();

  static http.Client _credentialedClient() {
    // Late import so non-web builds (if any) don't try to use it.
    final c = http.Client();
    return c;
  }

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

  Future<PasskeySummary> registerNewPasskey({String? nickname}) async {
    if (!isAvailable) {
      throw PasskeyException(
        'This browser doesn\'t support passkeys. Try Chrome/Safari/Edge on a recent OS.',
      );
    }

    // 1. Ask the server for the challenge + options.
    final startRes = await _client.post(
      Uri.parse('$_baseUrl/register/start'),
      headers: {'Content-Type': 'application/json'},
    );
    if (startRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(startRes.body, 'Could not start passkey registration.'),
      );
    }
    final startJson = jsonDecode(startRes.body) as Map<String, dynamic>;
    final nonce = startJson['nonce'] as String;
    final options = startJson['options'] as Map<String, dynamic>;

    // 2. Hand the publicKey options to the browser. The platform shows
    //    the biometric prompt and returns a PublicKeyCredential.
    final publicKey =
        _coerceCreationOptions(options['publicKey'] as Map<String, dynamic>);
    final cred = await _callCredentialsCreate(publicKey);
    final credJson = _encodeAttestationCredential(cred);

    // 3. Send the result + the nickname back to the server.
    final finishRes = await _client.post(
      Uri.parse('$_baseUrl/register/finish'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'nonce': nonce,
        'credential': credJson,
        if (nickname != null && nickname.trim().isNotEmpty)
          'nickname': nickname.trim(),
      }),
    );
    if (finishRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(finishRes.body, 'Could not save the new passkey.'),
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
      throw PasskeyException(
        'This browser doesn\'t support passkeys. Try Chrome/Safari/Edge on a recent OS.',
      );
    }
    if (username.trim().isEmpty) {
      throw PasskeyException('Enter your username first.');
    }

    final startRes = await _client.post(
      Uri.parse('$_baseUrl/login/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username.trim()}),
    );
    if (startRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(startRes.body, 'Could not start passkey sign-in.'),
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
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'nonce': nonce, 'credential': credJson}),
    );
    if (finishRes.statusCode != 200) {
      throw PasskeyException(
        _decodeError(finishRes.body, 'Passkey sign-in failed.'),
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
        _decodeError(res.body, 'Could not load passkeys.'),
      );
    }
    final raw = jsonDecode(res.body) as List<dynamic>;
    return raw
        .map((e) => PasskeySummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> remove(String id) async {
    final res = await _client.delete(Uri.parse('$_baseUrl/$id'));
    if (res.statusCode == 401) {
      throw UnauthorizedException();
    }
    if (res.statusCode != 204) {
      throw PasskeyException(
        _decodeError(res.body, 'Could not remove the passkey.'),
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
  final promise =
      credentials.callMethod<JSPromise<JSAny?>>('create'.toJS, wrap);
  final result = (await promise.toDart) as JSObject?;
  if (result == null) {
    throw PasskeyException('Passkey enrolment was cancelled.');
  }
  return result;
}

Future<JSObject> _callCredentialsGet(JSObject publicKey) async {
  final wrap = _emptyJsObject();
  wrap['publicKey'] = publicKey;
  final navigator = globalContext['navigator'] as JSObject;
  final credentials = navigator['credentials'] as JSObject;
  final promise =
      credentials.callMethod<JSPromise<JSAny?>>('get'.toJS, wrap);
  final result = (await promise.toDart) as JSObject?;
  if (result == null) {
    throw PasskeyException('Passkey sign-in was cancelled.');
  }
  return result;
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
