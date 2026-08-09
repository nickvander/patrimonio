import '../../utils/home_widget_snapshot.dart';

/// No-op bridge for web (and any non-Android platform): there is no home
/// screen to put a widget on.
Future<void> pushHomeWidget(HomeWidgetSnapshot snapshot) async {}

/// Never launched from a widget off Android.
Future<Uri?> initialHomeWidgetLaunch() async => null;

/// No widget, no taps.
Stream<Uri?> homeWidgetClicks() => const Stream<Uri?>.empty();
