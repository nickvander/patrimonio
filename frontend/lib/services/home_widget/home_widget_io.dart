import 'dart:io' show Platform;

import 'package:home_widget/home_widget.dart';

import '../../utils/home_widget_snapshot.dart';

/// Every provider declared in AndroidManifest.xml. Android lists one picker
/// entry per provider, so the three size variants are three receivers — and an
/// update broadcast targets ONE of them, so a push that named only the default
/// would leave a placed small/large widget frozen on stale values.
const List<String> _androidProviders = [
  'com.patrimonio.patrimonio.PatrimonioWidgetProvider',
  'com.patrimonio.patrimonio.PatrimonioWidgetProviderSmall',
  'com.patrimonio.patrimonio.PatrimonioWidgetProviderLarge',
];

/// Publish [snapshot] to the Android home-screen widgets and ask them to
/// redraw.
///
/// Best-effort by design: this runs on every dashboard load, and a widget that
/// can't be updated (none placed, plugin missing, OEM restriction) must never
/// surface an error into a data refresh the user actually asked for. Failures
/// are swallowed — the widget simply keeps its previous values, which the
/// freshness line already labels honestly.
Future<void> pushHomeWidget(HomeWidgetSnapshot snapshot) async {
  // iOS/macOS/Linux have no provider registered; the test VM reports linux.
  if (!Platform.isAndroid) return;
  try {
    for (final entry in snapshot.toWidgetData().entries) {
      await HomeWidget.saveWidgetData<String>(entry.key, entry.value);
    }
    for (final provider in _androidProviders) {
      await HomeWidget.updateWidget(qualifiedAndroidName: provider);
    }
  } catch (_) {
    // Intentionally silent — see the doc comment.
  }
}

/// The `patrimonio://` URI the app was launched with from a widget tap, or
/// null for an ordinary launch. `patrimonio://sync` means the user pressed the
/// widget's sync glyph and expects an actual sync, not just the app opening.
Future<Uri?> initialHomeWidgetLaunch() async {
  if (!Platform.isAndroid) return null;
  try {
    return await HomeWidget.initiallyLaunchedFromHomeWidget();
  } catch (_) {
    return null;
  }
}

/// Widget taps arriving while the app is already running — the app is
/// `launchMode="singleTop"`, so a tap on a warm app never re-runs the initial
/// launch path and would otherwise do nothing at all.
Stream<Uri?> homeWidgetClicks() {
  if (!Platform.isAndroid) return const Stream<Uri?>.empty();
  return HomeWidget.widgetClicked;
}
