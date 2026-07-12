// Native implementation: there is no page location. Navigation hands off to the
// external browser; the "current URL" is empty (no OAuth-return params to read).
import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

void navigateTo(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
}

String currentUrl() => '';
