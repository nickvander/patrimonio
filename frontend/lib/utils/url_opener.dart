// Platform seam for opening a URL via the browser window.
//
// TransactionsTab's CSV export hands the download off to the browser
// (`window.open` — the backend replies with Content-Disposition:
// attachment). `package:web` only compiles for the web/JS target, so
// importing it directly made the widget — and therefore any widget test
// that pumps it — impossible to compile under the Dart test VM
// (`flutter test`). Same pattern as services/api_platform.dart: the
// conditional export resolves to the real web implementation in a
// browser build and to a no-op stub on the VM.
export 'url_opener_stub.dart'
    if (dart.library.js_interop) 'url_opener_web.dart';
