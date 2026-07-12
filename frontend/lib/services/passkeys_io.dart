// Native (Android/iOS/desktop) passkey stub.
//
// Passkeys are implemented against the browser WebAuthn JS API
// (`navigator.credentials`), which has no native equivalent wired up in this
// app. A proper native passkey flow (Android Credential Manager / iOS
// AuthenticationServices) is a separate piece of work. Until then, the native
// build reports passkeys as unavailable: [isAvailable] is false — so the
// passkey sign-in button and registration UI are hidden — and every action
// throws [PasskeyException] as a safe fallback. Password + TOTP is the native
// auth path.
import 'auth_service.dart';
import 'passkeys_types.dart';

class PasskeyService {
  PasskeyService._();
  static final PasskeyService instance = PasskeyService._();

  /// Passkeys are not supported on native yet — callers gate their UI on this.
  bool get isAvailable => false;

  PasskeyException _unsupported() => PasskeyException(
        'Passkeys are not yet supported in the app. Use your password to sign '
        'in.',
      );

  Future<PasskeySummary> registerNewPasskey({
    String? nickname,
    bool hardwareKeyOnly = false,
  }) async =>
      throw _unsupported();

  Future<AuthUser> signInWithPasskey({required String username}) async =>
      throw _unsupported();

  Future<({Map<String, dynamic> credential, String nonce})>
      reauthWithPasskey() async => throw _unsupported();

  Future<void> setPasswordWithPasskey({
    required Map<String, dynamic> credential,
    required String nonce,
    required String newPassword,
  }) async =>
      throw _unsupported();

  /// Signed-out/native builds have no passkeys. Return empty rather than throw
  /// so the Security screen just shows the "unavailable" state.
  Future<List<PasskeySummary>> list() async => const [];

  Future<void> remove(String id) async => throw _unsupported();
}
