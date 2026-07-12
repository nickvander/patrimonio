// Platform seam for Plaid Link + its OAuth-redirect resume flow.
//
// The web build persists the in-flight link token in `localStorage` and reads
// the OAuth return off `window.location` (`plaid_oauth_web.dart`). Native builds
// let the Plaid SDK handle OAuth bank redirects and keep only an in-memory note
// (`plaid_oauth_io.dart`). The shared [PendingPlaidOAuth] type is re-exported so
// callers import only `services/plaid_oauth.dart`.
//
// Web has `dart.library.js_interop`; native and the Dart test VM take the
// default (io) impl.
export 'plaid_oauth_io.dart' if (dart.library.js_interop) 'plaid_oauth_web.dart';
export 'plaid_oauth_types.dart';
