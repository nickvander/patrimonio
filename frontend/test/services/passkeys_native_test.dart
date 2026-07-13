// Native passkey seam (passkeys_io.dart) — the parts that run on the VM.
//
// The full ceremony needs a real Android device (Credential Manager), but
// the pure logic around it is testable here: the availability gate that
// keeps the passkey UI hidden on the test VM / desktop, the transports
// extraction that protects webauthn-rs from unknown enum values, and the
// PlatformException → PasskeyException mapping (bilingual).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/passkeys_io.dart';
import 'package:patrimonio/services/passkeys_types.dart';
import 'package:patrimonio/utils/app_locale.dart';

void main() {
  group('availability gate (test VM = not Android)', () {
    test('isAvailable is false so the passkey UI stays hidden', () {
      expect(PasskeyService.instance.isAvailable, isFalse);
    });

    test('ceremonies throw PasskeyException cleanly, list returns empty',
        () async {
      expect(
        () => PasskeyService.instance.registerNewPasskey(),
        throwsA(isA<PasskeyException>()),
      );
      expect(
        () => PasskeyService.instance.signInWithPasskey(username: 'nick'),
        throwsA(isA<PasskeyException>()),
      );
      expect(
        () => PasskeyService.instance.reauthWithPasskey(),
        throwsA(isA<PasskeyException>()),
      );
      expect(await PasskeyService.instance.list(), isEmpty);
    });
  });

  group('extractTransports', () {
    test('lifts response.transports out of the credential', () {
      final cred = <String, dynamic>{
        'id': 'abc',
        'response': <String, dynamic>{
          'clientDataJSON': 'x',
          'transports': ['internal', 'hybrid'],
        },
      };
      final t = extractTransports(cred);
      expect(t, ['internal', 'hybrid']);
      // Removed from the response object — webauthn-rs' typed
      // response.transports rejects unknown values ("hybrid") on some
      // versions, failing the whole registration.
      expect((cred['response'] as Map).containsKey('transports'), isFalse);
    });

    test('accepts top-level transports and strips it', () {
      final cred = <String, dynamic>{
        'id': 'abc',
        'transports': ['usb'],
        'response': <String, dynamic>{'clientDataJSON': 'x'},
      };
      expect(extractTransports(cred), ['usb']);
      expect(cred.containsKey('transports'), isFalse);
    });

    test('returns null when absent or empty', () {
      expect(extractTransports({'response': <String, dynamic>{}}), isNull);
      expect(
        extractTransports({
          'response': <String, dynamic>{'transports': <String>[]},
        }),
        isNull,
      );
    });
  });

  group('mapNativeCredentialError', () {
    tearDown(() => localeNotifier.value = null);

    PlatformException pe(String code, [String? message]) =>
        PlatformException(code: code, message: message);

    test('cancellation maps to the retry message (en)', () {
      final e = mapNativeCredentialError(
        pe('android.credentials.CreateCredentialException.TYPE_USER_CANCELED'),
        registering: true,
      );
      expect(e.message, contains('cancelled or timed out'));
    });

    test('cancellation maps to the retry message (es)', () {
      localeNotifier.value = const Locale('es');
      final e = mapNativeCredentialError(
        pe('android.credentials.CreateCredentialException.TYPE_USER_CANCELED'),
        registering: true,
      );
      expect(e.message, contains('se canceló o expiró'));
    });

    test('NoCredentialException maps to "no matching passkey"', () {
      final e = mapNativeCredentialError(
        pe('androidx.credentials.TYPE_NO_CREDENTIAL'),
        registering: false,
      );
      expect(e.message, contains('No matching passkey'));
    });

    test('DOM InvalidStateError while registering → already-exists message',
        () {
      final e = mapNativeCredentialError(
        pe(
          'androidx.credentials.TYPE_CREATE_PUBLIC_KEY_CREDENTIAL_DOM_EXCEPTION/'
          'androidx.credentials.TYPE_INVALID_STATE_ERROR',
        ),
        registering: true,
      );
      expect(e.message, contains('already exists'));
    });

    test('DOM SecurityError → assetlinks hint', () {
      final e = mapNativeCredentialError(
        pe(
          'androidx.credentials.TYPE_GET_PUBLIC_KEY_CREDENTIAL_DOM_EXCEPTION/'
          'androidx.credentials.TYPE_SECURITY_ERROR',
        ),
        registering: false,
      );
      expect(e.message, contains('assetlinks.json'));
    });

    test('unknown codes fall through with the detail preserved', () {
      final e = mapNativeCredentialError(
        pe('SOMETHING_ELSE', 'weird provider failure'),
        registering: true,
      );
      expect(e.message, contains('weird provider failure'));
    });
  });
}
