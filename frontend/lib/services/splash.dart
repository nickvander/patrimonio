// Platform seam for the HTML boot splash.
//
// The web build ships an HTML/JS splash in index.html that Flutter drives via
// two JS hooks (`__splashProgress` / `__splashDone`) while it initialises. Those
// live in `dart:js_interop`, which only compiles for the web target — importing
// it directly kept `main.dart` from compiling for Android. This conditional
// export hands `main.dart` no-op splash functions off the web (native shows the
// platform's own launch screen instead).
export 'splash_stub.dart' if (dart.library.js_interop) 'splash_web.dart';
