import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

/// The app's active UI locale. Lives in a **web-free** util file (no
/// dart:html / package:web, unlike `Preferences`) so pure-Dart code such as
/// `prettyCategory` can read the current language without dragging web-only
/// deps into the test VM (see MEMORY: patrimonio-flutter-widget-test-web-dep).
///
/// `main.dart` seeds the initial value at startup; the dashboard language
/// toggle updates it; `MaterialApp` rebuilds the whole tree on change, so
/// anything that reads it re-runs with the new locale.
final ValueNotifier<Locale?> localeNotifier = _buildLocaleNotifier();

ValueNotifier<Locale?> _buildLocaleNotifier() {
  final notifier = ValueNotifier<Locale?>(null);
  // Keep package:intl in lock-step with the app locale. This listener is
  // registered at module init — before any ValueListenableBuilder subscribes
  // — and ValueNotifier calls listeners in registration order, so Intl is
  // re-pointed *before* MaterialApp rebuilds and the ~36 DateFormat call
  // sites re-run with the new locale.
  notifier.addListener(() => syncIntlLocale(notifier.value));
  return notifier;
}

/// Points `package:intl` at [locale] so `DateFormat` (date group headers,
/// chart axes, statement labels, …) renders in the app language instead of
/// always falling back to en_US.
///
/// The notifier listener above covers locale *changes*; `main()` also calls
/// this explicitly for the startup path, because seeding the notifier with
/// `null` (no saved language) doesn't change its value and so never fires
/// the listener.
///
/// With `date_symbol_data_local.dart` the locale data is bundled and
/// initialization is synchronous (the returned Future is already resolved),
/// so callers may safely fire-and-forget; the Future is returned for tests
/// that prefer to await it.
Future<void> syncIntlLocale(Locale? locale) {
  // Locale.toString() yields underscore form ('es', 'es_MX') — the format
  // Intl expects. null = no saved preference: leave Intl on its platform
  // default, matching MaterialApp's own locale resolution.
  Intl.defaultLocale = locale?.toString();
  return initializeDateFormatting(locale?.toString());
}
