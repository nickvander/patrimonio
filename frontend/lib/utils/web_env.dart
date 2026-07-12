// Platform seam for the two browser-window operations the dashboard needs:
// navigating the whole tab to a URL (used to kick off Coinbase/OAuth flows that
// bounce through an external site) and reading the current URL (to detect an
// OAuth return via query params).
//
// On the web these hit `window.location`. On native there is no page location:
// [navigateTo] opens the URL in the external browser (url_launcher) and
// [currentUrl] returns an empty string (no query params to parse).
export 'web_env_stub.dart'
    if (dart.library.js_interop) 'web_env_web.dart'
    if (dart.library.io) 'web_env_io.dart';
