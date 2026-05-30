// Web implementation of the [ApiService] platform seam.
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;

String currentHost() => web.window.location.hostname.isEmpty
    ? 'localhost'
    : web.window.location.hostname;

/// Credentialed client: `withCredentials` is required for the browser to
/// send (and accept) the session cookie on cross-origin XHRs in dev, and
/// is harmless same-origin in production. Preserves the exact behaviour
/// ApiService had before the platform seam was extracted.
http.Client createApiClient() => BrowserClient()..withCredentials = true;
