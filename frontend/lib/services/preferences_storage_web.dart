// Web implementation of the Preferences raw store — a thin wrapper over
// window.localStorage. Selected via the conditional import in preferences.dart
// (only compiled on the web platform). Private-browsing modes can throw on
// localStorage access, so both calls swallow errors.
import 'package:web/web.dart' as web;

// localStorage is synchronous, so there's nothing to preload.
Future<void> initPrefsStorage() async {}

String? prefsRead(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void prefsWrite(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {/* swallow */}
}
