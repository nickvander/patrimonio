// Web implementation of the URL-opener seam.
import 'package:web/web.dart' as web;

/// Open [url] in the current tab. Used for the CSV-export hand-off:
/// the backend responds with Content-Disposition: attachment, so the
/// browser downloads the file instead of navigating away.
void openUrlSameTab(String url) {
  web.window.open(url, '_self');
}
