/// What the Android home-screen widget displays, already rendered to strings.
///
/// **All formatting happens here, in Dart, never in the Kotlin widget.** The
/// widget is a `RemoteViews` tree that can only set text on a TextView — it has
/// no access to `utils/currency.dart`, the reporting-currency preference, or
/// the active locale, so a native-side `String.format` would be a fourth,
/// unreviewed money formatter that quietly disagrees with the app above it
/// (`$1,618,279` vs `1618279.0`). Formatting here keeps the single source of
/// truth the money rules already have.
///
/// Pure data + pure builder, so the layout decisions are unit-testable without
/// an emulator — the only part of a home-screen widget that CAN be tested off
/// device.
library;

import 'package:intl/intl.dart';

import 'currency.dart';

/// The rendered widget payload. Null fields mean "the app has no value for
/// this yet" and render as a placeholder rather than a stale or invented
/// number; `show*` mirror the user's Settings toggles.
class HomeWidgetSnapshot {
  /// Net worth in the reporting currency, preformatted (`$1,618,279`).
  final String? netWorth;

  /// USD/MXN rate, preformatted for the locale (`17.15`).
  final String? fxRate;

  /// When the app last refreshed, preformatted (`2h ago`).
  final String? syncedAt;

  /// The same age, ultra-short (`2h`, `now`).
  ///
  /// The compact layout puts the rate and the age on ONE line beside a sync
  /// icon; at two grid columns `USD/MXN 17.15 · just now` ellipsed to
  /// `USD/MXN 17.15 · j…`, which is worse than useless — it looks broken and
  /// says nothing. Shortening the AGE rather than dropping the `USD/MXN`
  /// label keeps the rate unambiguous (a bare `17.15` could be anything).
  ///
  /// Both forms cross the bridge because only the provider knows which layout
  /// it is about to inflate — and formatting stays here rather than moving a
  /// substring rule into Kotlin.
  final String? syncedAtShort;

  final bool showNetWorth;
  final bool showFx;
  final bool showSync;

  const HomeWidgetSnapshot({
    this.netWorth,
    this.fxRate,
    this.syncedAt,
    this.syncedAtShort,
    this.showNetWorth = true,
    this.showFx = true,
    this.showSync = true,
  });

  /// True when every section is switched off — the widget then renders a
  /// single "turn something on in Settings" line instead of an empty card the
  /// user would read as broken.
  bool get isEmpty => !showNetWorth && !showFx && !showSync;

  /// Flat string map for the native side. Values are the ONLY contract with
  /// Kotlin: it reads these keys and sets them on TextViews, nothing more.
  /// Booleans go over as `'true'`/`'false'` because the bridge stores strings.
  Map<String, String> toWidgetData() => {
    'net_worth': netWorth ?? '',
    'fx_rate': fxRate ?? '',
    'synced_at': syncedAt ?? '',
    'synced_at_short': syncedAtShort ?? '',
    'show_net_worth': showNetWorth.toString(),
    'show_fx': showFx.toString(),
    'show_sync': showSync.toString(),
  };
}

/// Build the snapshot from the dashboard's live values.
///
/// [netWorthUsd] is base-currency, scaled by [conversionFactor] like every
/// other figure on the dashboard. [now] is injected so the "2h ago" text is
/// testable without a clock.
///
/// Net worth is deliberately rendered with NO decimal places: the widget is a
/// glance target on a small tile, and `$1,618,279.43` either wraps or ellipses
/// to a misread on a 2x1 cell. The app is one tap away for the cents.
HomeWidgetSnapshot buildHomeWidgetSnapshot({
  required double? netWorthUsd,
  required double conversionFactor,
  required String reportingCurrency,
  required double? usdMxnRate,
  required DateTime? syncedAt,
  required DateTime now,
  required bool showNetWorth,
  required bool showFx,
  required bool showSync,
  HomeWidgetAgeLabels labels = const HomeWidgetAgeLabels(),
}) {
  String? money;
  if (netWorthUsd != null) {
    final fmt = NumberFormat.currency(
      name: reportingCurrency,
      symbol: currencySymbol(reportingCurrency),
      decimalDigits: 0,
    );
    money = fmt.format(netWorthUsd * conversionFactor);
  }
  return HomeWidgetSnapshot(
    netWorth: money,
    // A rate is a plain number, not money — two decimals, no glyph. The
    // label ("USD/MXN") lives in the layout so it isn't re-translated here.
    fxRate: (usdMxnRate != null && usdMxnRate > 0)
        ? usdMxnRate.toStringAsFixed(2)
        : null,
    syncedAt: syncedAt == null
        ? null
        : formatWidgetAge(syncedAt, now, labels: labels),
    syncedAtShort: syncedAt == null
        ? null
        : formatWidgetAge(syncedAt, now, labels: labels.short),
    showNetWorth: showNetWorth,
    showFx: showFx,
    showSync: showSync,
  );
}

/// Compact relative age for the widget's freshness line.
///
/// The widget only updates when the app runs (this is the app-pushed design —
/// no background networking, no WorkManager), so its numbers CAN be hours old.
/// Showing the age is what makes that honest instead of a silently stale
/// figure the user trusts as live. Deliberately coarse and unlocalized-numeric
/// — see `homeWidgetAgeLabels` for how the units are supplied.
///
/// A [syncedAt] in the future (clock skew after a timezone change) reads as
/// "now" rather than a negative age.
String formatWidgetAge(
  DateTime syncedAt,
  DateTime now, {
  HomeWidgetAgeLabels labels = const HomeWidgetAgeLabels(),
}) {
  final delta = now.difference(syncedAt);
  if (delta.isNegative || delta.inMinutes < 1) return labels.justNow;
  if (delta.inMinutes < 60) return labels.minutes(delta.inMinutes);
  if (delta.inHours < 24) return labels.hours(delta.inHours);
  return labels.days(delta.inDays);
}

/// The unit words for [formatWidgetAge], injected so the caller can pass
/// localized strings from `AppLocalizations` (the widget is built off the
/// app's active locale, same as everything else the user sees).
class HomeWidgetAgeLabels {
  final String justNow;
  final String Function(int) minutes;
  final String Function(int) hours;
  final String Function(int) days;

  /// Ultra-short forms for [HomeWidgetSnapshot.syncedAtShort]. Defaults strip
  /// the trailing "ago" — the unit letter alone reads as an age next to a
  /// rate, and it is the difference between fitting and ellipsing at two grid
  /// columns. Callers pass localized words for the "now" case only; `5m`/`2h`
  /// are unit letters, not words, and stay as they are in both locales.
  final String justNowShort;

  const HomeWidgetAgeLabels({
    this.justNow = 'just now',
    this.justNowShort = 'now',
    this.minutes = _defaultMinutes,
    this.hours = _defaultHours,
    this.days = _defaultDays,
  });

  /// This label set with the ultra-short renderings substituted.
  HomeWidgetAgeLabels get short => HomeWidgetAgeLabels(
    justNow: justNowShort,
    justNowShort: justNowShort,
    minutes: (n) => '${n}m',
    hours: (n) => '${n}h',
    days: (n) => '${n}d',
  );

  static String _defaultMinutes(int n) => '${n}m ago';
  static String _defaultHours(int n) => '${n}h ago';
  static String _defaultDays(int n) => '${n}d ago';
}
