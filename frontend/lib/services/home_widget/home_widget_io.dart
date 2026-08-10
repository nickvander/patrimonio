import 'dart:io' show Platform;

import 'package:home_widget/home_widget.dart';

import '../../utils/home_widget_snapshot.dart';
import '../../utils/home_widget_sparkline.dart';
import '../../utils/sparkline_geometry.dart';

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
  List<double> fxTrend = const [],
}) async {
  // iOS/macOS/Linux have no provider registered; the test VM reports linux.
  if (!Platform.isAndroid) return;
  // The sparkline is what keeps the tile from being a mostly-empty card: two
  // lines of text cannot fill a ~110dp launcher row, a trend can. Rendered to
  // PNG bytes HERE with a PictureRecorder — deliberately not through
  // HomeWidget.renderFlutterWidget, whose internal Column gave the paint an
  // unbounded height and, in release builds (asserts stripped), a silently
  // BLANK image; see renderSparklinePng. The provider only decodes a bitmap.
  //
  // In its own try: a chart failure downgrades the widget to text-only, it
  // must never block the numbers. (The first version had one try around
  // both, so a throwing render would have silently frozen the text too.)
  try {
    // Two charts, one slot: the provider shows the net-worth trend normally
    // and the RATE trend when the tile is configured down to FX-only — a
    // rate tile with the net-worth chart suppressed used to be half empty.
    // Each series keeps its own color — net worth green, rate blue — so the
    // shared chart slot is self-identifying (see sparklineFxColor).
    for (final (key, values, color) in [
      ('chart_path', trend, null),
      ('fx_chart_path', fxTrend, sparklineFxColor),
    ]) {
      final png = values.length >= 2
          ? await renderSparklinePng(
              thinSparkline(values),
              line: color ?? sparklineNetWorthColor,
            )
          : null;
      if (png != null) {
        await HomeWidget.saveFile(key, png, extension: 'png');
      } else {
        // No plottable history: clear the stale path (this also deletes the
        // managed file) so the provider hides the image instead of showing
        // last month's line under today's number.
        await HomeWidget.saveWidgetData<String?>(key, null);
      }
    }
  } catch (_) {
    // Charts are decoration; the numbers below must still go out.
  }
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
