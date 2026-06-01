import 'package:flutter/widgets.dart';

/// The app's active UI locale. Lives in a **web-free** util file (no
/// dart:html / package:web, unlike `Preferences`) so pure-Dart code such as
/// `prettyCategory` can read the current language without dragging web-only
/// deps into the test VM (see MEMORY: patrimonio-flutter-widget-test-web-dep).
///
/// `main.dart` seeds the initial value at startup; the dashboard language
/// toggle updates it; `MaterialApp` rebuilds the whole tree on change, so
/// anything that reads it re-runs with the new locale.
final ValueNotifier<Locale?> localeNotifier = ValueNotifier<Locale?>(null);
