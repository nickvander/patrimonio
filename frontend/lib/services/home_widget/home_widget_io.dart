import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show Size;
import 'package:home_widget/home_widget.dart';

import '../../utils/home_widget_snapshot.dart';
import '../../utils/sparkline_geometry.dart';
import '../../widgets/home_widget_sparkline.dart';

/// Every provider declared in AndroidManifest.xml. Android lists one picker
/// entry per provider, so each offered size is a receiver — and an update
/// broadcast targets ONE of them, so a push naming only the default would
/// leave a placed small widget frozen on stale values. **Adding a size variant
/// means adding it here too**, or it silently never updates.
const List<String> _androidProviders = [
  'com.patrimonio.patrimonio.PatrimonioWidgetProvider',
  'com.patrimonio.patrimonio.PatrimonioWidgetProviderSmall',
];

/// Publish [snapshot] to the Android home-screen widgets and ask them to
/// redraw.
///
/// Best-effort by design: this runs on every dashboard load, and a widget that
/// can't be updated (none placed, plugin missing, OEM restriction) must never
/// surface an error into a data refresh the user actually asked for. Failures
/// are swallowed — the widget simply keeps its previous values, which the
/// freshness line already labels honestly.
Future<void> pushHomeWidget(
  HomeWidgetSnapshot snapshot, {
  List<double> trend = const [],
}) async {
  // iOS/macOS/Linux have no provider registered; the test VM reports linux.
  if (!Platform.isAndroid) return;
  try {
    // The sparkline is what keeps the tile from being a mostly-empty card:
    // two lines of text cannot fill a ~110dp launcher row, a trend can.
    // Rendered off-screen to a PNG whose PATH rides the same KV bridge
    // ('chart_path'); the provider only decodes and sets a bitmap. Thinned
    // first — a year of daily points is sub-2px segments on a 600px bitmap.
    if (trend.length >= 2) {
      await HomeWidget.renderFlutterWidget(
        HomeWidgetSparkline(values: thinSparkline(trend)),
        key: 'chart_path',
        logicalSize: const Size(600, 140),
      );
    } else {
      // No plottable history: clear the stale path so the provider hides the
      // image instead of showing last month's line under today's number.
      await HomeWidget.saveWidgetData<String?>('chart_path', null);
    }
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
