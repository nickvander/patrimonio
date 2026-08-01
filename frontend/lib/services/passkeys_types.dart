// Web-free passkey data types, shared by the web implementation
// (`passkeys_web.dart`) and the native stub (`passkeys_io.dart`). Kept out of
// either platform file so both can compile without pulling in the other's
// imports.

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

/// Thrown when the platform doesn't expose a WebAuthn API or the user cancels
/// the platform prompt. We catch and surface this as a user-friendly snackbar
/// at the call site.
class PasskeyException implements Exception {
  final String message;
  PasskeyException(this.message);
  @override
  String toString() => message;
}
