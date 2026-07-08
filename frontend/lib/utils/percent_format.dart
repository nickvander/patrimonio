import 'package:flutter/widgets.dart';

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
/// Negatives keep their bare `-`; positives carry no sign, so call sites that
/// want an explicit leading `+` keep prepending it and the two never collide.
///
/// The app ships exactly two locales (en, es), so rather than route through
/// `NumberFormat` — whose `decimalPercentPattern` multiplies by 100 and
/// round-trips the value, shifting exact `.5` boundaries by one digit vs the
/// old `toStringAsFixed` — this formats the number directly. That keeps the en
/// output *byte-identical* to the previous `'${value.toStringAsFixed(digits)}%'`
/// and gives es the comma decimal + non-breaking space it expects.
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
  // toStringAsFixed IS the old en behavior — reuse it verbatim so en can't drift.
  final fixed = value.toStringAsFixed(digits);
  if (!_isEs(locale)) return '$fixed%';
  // es: comma decimal + non-breaking space before %. Grouping is off (a bare
  // toStringAsFixed has none), so the only '.' is the decimal point.
  return '${fixed.replaceAll('.', ',')} %';
}

/// Wraps an already-formatted percentage *number* string (e.g. `"88.6"`, `"85"`)
/// with the locale's decimal separator + percent spacing — for the
/// variable-precision callers (whole-number-or-one-decimal, like the
/// rebalancing card) that don't fit [formatPercent]'s fixed `digits`.
/// en → `"85%"` (unchanged); es → `"85 %"` (NBSP before %).
String localizePercentString(BuildContext context, String number) =>
    _isEs(Localizations.localeOf(context).toString())
        ? '${number.replaceAll('.', ',')} %'
        : '$number%';

/// Localizes just the decimal separator of an already-formatted number string
/// (no percent sign) — e.g. a `"+3.6"` percentage-point delta becomes `"+3,6"`
/// in es while en is unchanged.
String localizeNumberString(BuildContext context, String number) =>
    _isEs(Localizations.localeOf(context).toString())
        ? number.replaceAll('.', ',')
        : number;

bool _isEs(String locale) => locale.toLowerCase().startsWith('es');
