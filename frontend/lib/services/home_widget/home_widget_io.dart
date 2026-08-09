import 'dart:io' show Platform;

import 'package:home_widget/home_widget.dart';

import '../../utils/home_widget_snapshot.dart';

/// Android app group / provider wiring. `qualifiedAndroidName` must match the
/// receiver declared in AndroidManifest.xml, or the update broadcast lands
/// nowhere and the widget silently keeps its old text.
const String _androidProvider =
    'com.patrimonio.patrimonio.PatrimonioWidgetProvider';

/// Publish [snapshot] to the Android home-screen widget and ask it to redraw.
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
    await HomeWidget.updateWidget(qualifiedAndroidName: _androidProvider);
  } catch (_) {
    // Intentionally silent — see the doc comment.
  }
}
