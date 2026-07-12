// Web implementation: real `window.location` access.
import 'package:web/web.dart' as web;

/// Navigate the whole tab to [url] (used for full-page OAuth redirects).
void navigateTo(String url) {
  web.window.location.href = url;
}

/// The current page URL, so callers can inspect OAuth-return query params.
String currentUrl() => web.window.location.href;
