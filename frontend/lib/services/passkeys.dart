// Platform seam for passkeys (WebAuthn).
//
// The web build talks to `navigator.credentials` via `dart:js_interop`
// (`passkeys_web.dart`); native builds have no such API, so they fall back to
// `passkeys_io.dart`, which reports passkeys as unavailable. The shared data
// types live in `passkeys_types.dart` and are re-exported here so callers only
// ever import `services/passkeys.dart`.
//
// Web has `dart.library.js_interop`; native and the Dart test VM take the
// default (io) impl.
export 'passkeys_io.dart' if (dart.library.js_interop) 'passkeys_web.dart';
export 'passkeys_types.dart';
