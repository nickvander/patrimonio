// Where the app should reach the backend.
//
// On the WEB build this is irrelevant: the app is served same-origin behind the
// nginx `/api` proxy, so `api_platform_web.dart` derives everything from
// `window.location` and never consults this class.
//
// On a NATIVE build (the Android APK, iOS, desktop) there is no page origin —
// the user must tell the app which self-hosted backend to talk to. That value
// is entered on the Settings screen (see `backend_setup_screen.dart`),
// persisted with shared_preferences, and read back synchronously by
// `api_platform_io.dart` via [baseUrl].
//
// A compile-time default can also be baked in with
// `--dart-define=API_BASE_URL=https://your-host`; a value saved in the UI
// overrides it.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackendConfig {
  BackendConfig._();

  static const _prefsKey = 'patrimonio:backend_base_url';
  static const _cfIdKey = 'patrimonio:backend_cf_access_client_id';
  static const _cfSecretKey = 'patrimonio:backend_cf_access_client_secret';
  static const _compileDefault = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  /// The configured backend origin (scheme + host [+ port]), with no trailing
  /// slash and no `/api` suffix — e.g. `https://patrimonio.example.com`. Null
  /// until the user configures one. Held in memory so the synchronous
  /// `api_platform` seam can read it on every request.
  static final ValueNotifier<String?> baseUrlNotifier = ValueNotifier<String?>(
    _compileDefault.isEmpty ? null : normalize(_compileDefault),
  );

  static String? get baseUrl => baseUrlNotifier.value;

  static bool get isConfigured => baseUrl != null;

  /// Optional Cloudflare Access **service token** for deployments whose backend
  /// sits behind Cloudflare Zero Trust. A native app can't complete the
  /// interactive browser login CF Access normally requires, so instead a
  /// Service-Auth policy lets requests through when they carry the
  /// `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers. Held in memory
  /// (loaded in [load]) so the synchronous `apiExtraHeaders()` seam can stamp
  /// them onto every request. Null/empty when the deployment doesn't use
  /// Cloudflare Access — the common self-hosted case — in which case no extra
  /// headers are sent.
  static String? cfAccessClientId;
  static String? cfAccessClientSecret;

  static bool get hasCfAccessToken =>
      (cfAccessClientId?.isNotEmpty ?? false) &&
      (cfAccessClientSecret?.isNotEmpty ?? false);

  /// Load the saved backend URL (and optional Cloudflare Access token) into
  /// memory. Call once at startup, before the first API request. A UI-saved
  /// value wins over the compile-time default.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && saved.trim().isNotEmpty) {
      baseUrlNotifier.value = normalize(saved);
    }
    cfAccessClientId = prefs.getString(_cfIdKey);
    cfAccessClientSecret = prefs.getString(_cfSecretKey);
  }

  /// Persist [rawUrl] (and the optional Cloudflare Access service token) and
  /// update the in-memory values so subsequent requests use them immediately.
  /// Passing an empty/null [cfClientId]/[cfClientSecret] clears a previously
  /// stored token.
  static Future<void> save(
    String rawUrl, {
    String? cfClientId,
    String? cfClientSecret,
  }) async {
    final normalized = normalize(rawUrl);
    final id = cfClientId?.trim() ?? '';
    final secret = cfClientSecret?.trim() ?? '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, normalized);
    if (id.isEmpty || secret.isEmpty) {
      await prefs.remove(_cfIdKey);
      await prefs.remove(_cfSecretKey);
      cfAccessClientId = null;
      cfAccessClientSecret = null;
    } else {
      await prefs.setString(_cfIdKey, id);
      await prefs.setString(_cfSecretKey, secret);
      cfAccessClientId = id;
      cfAccessClientSecret = secret;
    }
    baseUrlNotifier.value = normalized;
  }

  /// Forget the configured backend and any stored Cloudflare Access token
  /// (used by "change server" / logout-to-setup).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await prefs.remove(_cfIdKey);
    await prefs.remove(_cfSecretKey);
    cfAccessClientId = null;
    cfAccessClientSecret = null;
    baseUrlNotifier.value = null;
  }

  /// Validate a candidate URL the way the setup screen should: must be an
  /// absolute http(s) URL with a host. Returns null when valid, or a short
  /// reason string when not.
  static String? validationError(String rawUrl) {
    final u = Uri.tryParse(rawUrl.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) {
      return 'Enter a full URL, e.g. https://patrimonio.example.com';
    }
    if (u.scheme != 'http' && u.scheme != 'https') {
      return 'URL must start with http:// or https://';
    }
    return null;
  }

  /// Strip a trailing slash and an accidentally-pasted `/api` suffix so the
  /// stored value is always a bare origin. Public so the setup screen can
  /// normalise before a connectivity pre-flight.
  static String normalize(String raw) {
    var u = raw.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/api')) {
      u = u.substring(0, u.length - 4);
      while (u.endsWith('/')) {
        u = u.substring(0, u.length - 1);
      }
    }
    return u;
  }
}
