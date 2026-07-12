// Native (Android/iOS/desktop) implementation of the Preferences raw store.
//
// The Preferences seam is synchronous (`prefsRead`/`prefsWrite`), matching the
// browser's synchronous localStorage. shared_preferences is async, so we bridge
// the gap by preloading every key into an in-memory cache once at startup
// (`initPrefsStorage`, awaited in main) and serving reads from the cache. Writes
// update the cache synchronously and fire-and-forget the async persist.
import 'package:shared_preferences/shared_preferences.dart';

SharedPreferences? _prefs;
final Map<String, String> _cache = {};

// Until `initPrefsStorage` runs, this backend is inert: reads return null and
// writes are dropped. `main()` awaits init before the first frame, so the real
// app is always initialised. Widget tests never run `main()`, so they see the
// old no-op-stub behaviour — critical for test isolation, since `_cache` is a
// process-global that would otherwise leak state between tests.
bool _initialized = false;

Future<void> initPrefsStorage() async {
  final prefs = await SharedPreferences.getInstance();
  _prefs = prefs;
  for (final key in prefs.getKeys()) {
    final value = prefs.get(key);
    if (value is String) {
      _cache[key] = value;
    }
  }
  _initialized = true;
}

String? prefsRead(String key) => _initialized ? _cache[key] : null;

void prefsWrite(String key, String value) {
  if (!_initialized) return;
  _cache[key] = value;
  // Fire-and-forget; the cache is the source of truth for the session.
  _prefs?.setString(key, value);
}
