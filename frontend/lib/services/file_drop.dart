// Platform seam for global drag-and-drop file import.
//
// Dropping files onto the page is a browser-only affordance built on
// `dart:js_interop` document listeners (`file_drop_web.dart`). Native builds
// have no page to drop onto — the import screen already gates the listener on
// `kIsWeb` — so they get a no-op stub (`file_drop_stub.dart`) that keeps the
// same API and compiles without `package:web`.
export 'file_drop_stub.dart'
    if (dart.library.js_interop) 'file_drop_web.dart';
