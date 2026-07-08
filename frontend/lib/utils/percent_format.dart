import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Locale-aware percentage formatter.
///
/// Takes a percentage *number* (e.g. `12.5` meaning 12.5%, NOT the ratio
/// `0.125`) and renders it with the decimal separator + percent-sign spacing
/// of the widget's locale:
///
/// - `en` → `"12.5%"` (period decimal, no space) — byte-identical to the old
///   hardcoded `'${value.toStringAsFixed(digits)}%'`.
/// - `es` → `"12,5 %"` (comma decimal, non-breaking space before `%`), the
///   Spanish convention.
///
/// The sign is whatever `NumberFormat` produces for the locale (a bare `-` for
/// negatives, nothing for positives). Call sites that want an explicit leading
/// `+` keep prepending it themselves and pass the raw value — since positives
/// carry no sign here, the two never collide.
///
/// Grouping is turned off so a value like `1234.5` stays `"1234.5%"` in en
/// (matching `toStringAsFixed`) rather than gaining a thousands separator.
String formatPercent(BuildContext context, double value, {int digits = 1}) =>
    formatPercentLocale(
      Localizations.localeOf(context).toString(),
      value,
      digits: digits,
    );

/// Locale-string variant of [formatPercent] for the rare call site that has no
/// [BuildContext] in scope (e.g. the pure `deriveNotifications` builder, which
/// only carries an `AppLocalizations` — pass its `localeName`).
String formatPercentLocale(String locale, double value, {int digits = 1}) {
  final fmt = NumberFormat.decimalPercentPattern(
    locale: locale,
    decimalDigits: digits,
  )..turnOffGrouping();
  // decimalPercentPattern multiplies by 100, so feed it the ratio.
  return fmt.format(value / 100);
}
