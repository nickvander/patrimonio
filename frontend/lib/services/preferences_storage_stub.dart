// Non-web fallback for the Preferences raw store (Dart test VM, native).
// There's no window.localStorage off the web platform, so reads return null
// and writes are no-ops. Keeping the `package:web` dependency behind this
// conditional import means importing Preferences in a widget test does NOT
// pull package:web into the test VM (see account_alerts_cache for the same
// pattern).
Future<void> initPrefsStorage() async {}
String? prefsRead(String key) => null;
void prefsWrite(String key, String value) {}
