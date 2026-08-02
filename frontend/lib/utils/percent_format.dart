import 'package:flutter/widgets.dart';

/// Locale-aware percentage formatter.
///
/// Takes a percentage *number* (e.g. `12.5` meaning 12.5%, NOT the ratio
/// `0.125`) and renders it with the decimal separator + percent-sign spacing
/// of the widget's locale.
///
/// The app ships exactly two locales — en and es (Mexican Spanish, es-MX) —
/// and CLDR es_MX uses the SAME conventions as en: period decimal, no space
/// before `%`. So both locales render `"12.5%"`. (An earlier revision gave es
/// Spain-style `"12,5 %"`; that clashed with the correct es-MX money format
/// `$1,000.00` on the same card and was removed.)
///
/// Negatives keep their bare `-`; positives carry no sign, so call sites that
/// want an explicit leading `+` keep prepending it and the two never collide.
///
/// Rather than route through `NumberFormat` — whose `decimalPercentPattern`
/// multiplies by 100 and round-trips the value, shifting exact `.5` boundaries
/// by one digit vs the old `toStringAsFixed` — this formats the number
/// directly. That keeps the output *byte-identical* to the previous
/// `'${value.toStringAsFixed(digits)}%'` in every locale.
String formatPercent(BuildContext context, double value, {int digits = 1}) =>
    formatPercentLocale(
      Localizations.localeOf(context).toString(),
      value,
      digits: digits,
    );

/// Locale-string variant of [formatPercent] for the rare call site that has no
/// [BuildContext] in scope (e.g. the pure `deriveNotifications` builder, which
/// only carries an `AppLocalizations` — pass its `localeName`).
///
/// en and es-MX share period decimals and no space before `%` (CLDR es_MX),
/// so every shipped locale formats identically; `locale` stays in the
/// signature as the seam for any future locale with different conventions.
String formatPercentLocale(String locale, double value, {int digits = 1}) =>
    // toStringAsFixed IS the historical behavior — reuse it verbatim so
    // rendered percents can't drift.
    '${value.toStringAsFixed(digits)}%';

/// Explicitly signed variant of [formatPercent]: non-negative values gain a
/// leading `+` (negatives already carry `-` from the number itself), so a
/// gain/loss percent always reads with a sign — the percent twin of the
/// `_signedMoney` idiom on the money side.
String formatSignedPercent(
  BuildContext context,
  double value, {
  int digits = 1,
}) => value >= 0
    ? '+${formatPercent(context, value, digits: digits)}'
    : formatPercent(context, value, digits: digits);

/// Wraps an already-formatted percentage *number* string (e.g. `"88.6"`, `"85"`)
/// with the locale's percent suffix — for the variable-precision callers
/// (whole-number-or-one-decimal, like the rebalancing card) that don't fit
/// [formatPercent]'s fixed `digits`. Both en and es-MX write `"85%"` (period
/// decimal, no space before `%`), so this is locale-independent today; the
/// `context` parameter stays as the seam for any future locale.
String localizePercentString(BuildContext context, String number) => '$number%';

/// Localizes just the decimal separator of an already-formatted number string
/// (no percent sign) — e.g. a `"+3.6"` percentage-point delta. es-MX uses
/// period decimals (CLDR es_MX), same as en, so this is currently a no-op for
/// both shipped locales. It stays in place — and call sites keep routing
/// through it — as the seam if a comma-decimal locale is ever added.
String localizeNumberString(BuildContext context, String number) => number;
