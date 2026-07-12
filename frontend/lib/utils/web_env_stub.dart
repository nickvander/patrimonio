// Fallback for platforms with neither dart:io nor js_interop (never selected in
// practice). No-op navigation, empty current URL.
void navigateTo(String url) {}

String currentUrl() => '';
