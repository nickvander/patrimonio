// Platform seam for the web-only bits of [ApiService].
//
// ApiService needs the browser's hostname (to build the API base URL) and
// a credentialed HTTP client (BrowserClient with withCredentials, so the
// session cookie rides along on cross-origin XHRs in dev). Both live in
// `package:web` / `package:http/browser_client.dart`, which only compile
// for the web/JS target. Importing them directly made ApiService — and
// therefore every widget that takes an ApiService — impossible to compile
// under the Dart test VM (`flutter test`).
//
// This conditional export hands ApiService a `currentHost()` +
// `createApiClient()` pair that resolves to the real web implementation
// in a browser build and to a VM-safe stub under `flutter test`. The stub
// is never used against a real server — tests inject their own fakes — so
// its plain client + 'localhost' host are only there to satisfy the
// compiler.
// Resolution order matters: web has `dart.library.js_interop`, native
// (Android/iOS/desktop) and the Dart test VM have `dart.library.io`. The io
// impl handles the native app *and* doubles as the test-VM stub (it defaults to
// localhost when no backend is configured, and tests inject fakes anyway), so
// the original pure stub is now only a belt-and-suspenders fallback.
export 'api_platform_stub.dart'
    if (dart.library.js_interop) 'api_platform_web.dart'
    if (dart.library.io) 'api_platform_io.dart';
