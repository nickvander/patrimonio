import 'dart:math' as math;
// Aliased: intl exports its own (bidi) TextDirection that would otherwise
// shadow the dart:ui one TextPainter needs.
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:intl/intl.dart';

double convertCurrency(
  double amount, {
  required String from,
  required String to,
  required double usdMxnRate,
}) {
  final source = from.toUpperCase();
  final target = to.toUpperCase();

  if (source == target) return amount;
  if (source == 'USD' && target == 'MXN') return amount * usdMxnRate;
  if (source == 'MXN' && target == 'USD') return amount / usdMxnRate;

  return amount;
}

/// Idiomatic currency symbols, keyed by ISO code. Money should read as
/// `$1,234.00` / `MX$47,651.01` — the ISO prefix ("USD 1,234.00") was
/// spreadsheet voice. The map is the single place to add a symbol; codes
/// without an entry fall back to the ISO code so nothing renders blank.
const Map<String, String> _currencySymbols = {
  'USD': '\$',
  // Peso amounts read as "MXN 47,651.01". The "MX$" glyph was being misread as
  // "MX" (a country code) and looked awkward next to "$" USD amounts; the ISO
  // code is unambiguous and matches what the user expects ("MXN").
  'MXN': 'MXN ',
};

/// The display glyph for a currency code: `$` / `MX$`, or "CODE " (ISO
/// prefix with a trailing space) for anything without an idiomatic symbol.
String currencySymbol(String currency) {
  final code = currency.toUpperCase();
  return _currencySymbols[code] ?? '$code ';
}

/// A `NumberFormat` for [currency] that renders the idiomatic symbol. Use
/// this anywhere a reusable formatter is needed (e.g. the dashboard's
/// `currencyFormat` passed down to cards) so every money string in the app
/// reads `$1,234.00` / `MX$47,651.01` rather than the old "USD 1,234.00".
NumberFormat moneyFormat(String currency) {
  final code = currency.toUpperCase();
  // `name` stays the ISO code so NumberFormat keeps the right
  // decimal/grouping conventions; `symbol` carries the display glyph.
  return NumberFormat.currency(name: code, symbol: currencySymbol(code));
}

String formatCurrencyAmount(double amount, String currency) {
  return moneyFormat(currency).format(amount);
}

/// Compact money for chart axis ticks: `$1.53M`, `MXN 6.74M`.
///
/// Never build axis ticks with `NumberFormat.compactSimpleCurrency`: intl's
/// simple-symbol table maps MXN to its *local* symbol `$`, so MXN axes are
/// indistinguishable from USD ones, and its sub-1000 output keeps currency
/// decimals on some magnitudes only (`$50.00` next to `$150` on one axis).
/// `compactCurrency` is no better — in es it renders the symbol as a suffix
/// (`6.74 MMXN`). This helper pairs the house [currencySymbol] glyph with a
/// locale-aware `NumberFormat.compact()` magnitude (no stray decimals), puts
/// the sign before the symbol like [moneyFormat] (`-$1.53M`), and uses
/// no-break spaces so a tick never wraps inside fl_chart's fixed
/// `reservedSize` title box.
String compactMoney(num value, String currency) {
  final sign = value < 0 ? '-' : '';
  final magnitude = NumberFormat.compact().format(value.abs());
  return '$sign${currencySymbol(currency)}$magnitude'
      .replaceAll(' ', '\u00A0');
}

/// Per-(locale, currency, range, font) memo for [compactMoneyAxisWidth] so
/// chart rebuilds (hover repaints every interaction frame) skip the
/// TextPainter layouts. The key space is bounded by the handful of live
/// charts; cleared wholesale in the unlikely event it grows past the cap.
final Map<String, double> _axisWidthCache = {};
const int _axisWidthCacheCap = 64;

/// Breathing room added to the widest measured tick: the visual gap between
/// label and plot area, plus slack for minor metric drift between the
/// measuring TextPainter and the composed chart text.
const double _axisTickPadding = 12;

/// fl_chart `reservedSize` for a money y-axis whose ticks come from
/// [compactMoney]: wide enough for the widest tick the axis can produce, in
/// the current locale and currency, without hardcoding a width that wastes
/// space in USD mode yet wraps or clips under the wider "MXN " prefix
/// ("MXN 6.75M" used to wrap its final "M"; "MXN 2.61K" clipped to "MXN 2." \u2014
/// a 10x misread).
///
/// [minValue]/[maxValue] are the axis extent in the DISPLAY currency \u2014 apply
/// any `conversionFactor` first, exactly as the tick builder does. The actual
/// tick positions don't need to be known (fl_chart may auto-pick intervals):
/// `NumberFormat.compact()` emits at most three significant digits, so
/// measuring the widest-digit candidate at every order of magnitude in the
/// range (plus the endpoints) bounds every tick fl_chart can place.
double compactMoneyAxisWidth(
  double minValue,
  double maxValue,
  String currency, {
  double fontSize = 10,
}) {
  final key =
      '${Intl.getCurrentLocale()}|$currency|$minValue|$maxValue|$fontSize';
  final cached = _axisWidthCache[key];
  if (cached != null) return cached;
  if (_axisWidthCache.length >= _axisWidthCacheCap) _axisWidthCache.clear();

  double widest = 0;
  for (final value in _axisWidthCandidates(minValue, maxValue)) {
    widest =
        math.max(widest, _tickTextWidth(compactMoney(value, currency), fontSize));
  }
  return _axisWidthCache[key] = (widest + _axisTickPadding).ceilToDouble();
}

/// Worst-case tick values for an axis range: 8.88 scaled through every decade
/// up to each endpoint's magnitude \u2014 "8" is the widest digit in most faces,
/// and three significant digits is `compact()`'s ceiling (fl_chart's
/// auto-intervals really do land on ticks like "MXN 2.61K", not round
/// numbers). The negative side is negated so the sign's width is measured
/// too, and the endpoints themselves are always included.
List<num> _axisWidthCandidates(double minValue, double maxValue) {
  final candidates = <num>[];
  void addDecades(double limit, double sign) {
    for (double v = 8.88; v <= limit; v *= 10) {
      candidates.add(sign * v);
    }
  }

  if (maxValue > 0) {
    addDecades(maxValue, 1);
    candidates.add(maxValue);
  }
  if (minValue < 0) {
    addDecades(-minValue, -1);
    candidates.add(minValue);
  }
  if (candidates.isEmpty) candidates.add(0);
  return candidates;
}

/// Laid-out width of one chart tick label, in the axis label style.
///
/// Public sibling of the money-axis measurement above, for axes whose ticks
/// aren't money — the net-worth chart measures its widest DATE label to know
/// how far the final, centre-anchored tick overhangs the plot. Lives here so
/// the "name Inter explicitly" caveat below has exactly one home.
double axisTickTextWidth(String text, {double fontSize = 10}) =>
    _tickTextWidth(text, fontSize);

/// Laid-out width of one tick label in the axis label style. Inter is named
/// explicitly because chart ticks inherit the UI family through
/// `DefaultTextStyle`, which a bare TextPainter doesn't see.
double _tickTextWidth(String text, double fontSize) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, fontFamily: 'Inter'),
    ),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = painter.size.width;
  painter.dispose();
  return width;
}

/// Magnitude at/above which DISPLAY money drops the cents: "$385,784" rather
/// than "$385,783.67", while "$9,999.99" keeps its cents. The threshold is
/// checked against the amount actually being displayed — i.e. AFTER any FX /
/// display-currency conversion — so the same balance can keep cents in USD
/// and drop them in MXN.
const double wholeMoneyThreshold = 10000;

/// Cents-less variants of currency formats, keyed by locale|code|symbol, so
/// hot paths (chart tooltips, long lists) don't rebuild a `NumberFormat` per
/// call.
final Map<String, NumberFormat> _wholeMoneyFormats = {};

/// House rule for money on DISPLAY surfaces (dashboard tiles, summary cards,
/// chart tooltips, projections, loan/holdings headlines).
extension MoneyDisplayFormat on NumberFormat {
  /// Formats [value] like [format], except that amounts whose absolute value
  /// is at least [wholeMoneyThreshold] render without cents, rounded to the
  /// nearest whole unit by `NumberFormat`'s own rounding (half away from
  /// zero: -12345.67 → "-$12,346", 10000.5 → "$10,001"). Locale, grouping,
  /// symbol, and sign placement are untouched — en and es-MX both keep their
  /// conventions.
  ///
  /// Do NOT use where exact precision is semantically required: transaction
  /// rows/ledgers, running balances being reconciled, CSV/exports, per-share
  /// or per-lot prices, tax-report figures, or text echoing user input.
  /// Those keep [format].
  ///
  /// Only meaningful on currency formats (anything [moneyFormat] /
  /// `NumberFormat.currency` produces — which is every money format in this
  /// app); on other formats the result is unspecified.
  String displayMoney(num value) {
    if (value.abs() < wholeMoneyThreshold) return format(value);
    return wholeMoney(value);
  }

  /// Formats [value] without cents regardless of magnitude — [displayMoney]
  /// with the [wholeMoneyThreshold] removed. For display surfaces where the
  /// figure is itself an estimate (e.g. projection tiles), so cents would
  /// imply precision the number doesn't have. Rounding, locale, grouping,
  /// symbol, and sign placement follow [displayMoney]; the same "not where
  /// exact precision is semantically required" caveat applies.
  ///
  /// Only meaningful on currency formats; on other formats [value] is
  /// formatted as-is.
  String wholeMoney(num value) {
    final name = currencyName;
    if (name == null) return format(value); // not a currency format
    // `this.` disambiguates from this library's top-level currencySymbol().
    final symbol = this.currencySymbol;
    final key = '$locale|$name|$symbol';
    final whole = _wholeMoneyFormats[key] ??= NumberFormat.currency(
      locale: locale,
      name: name,
      symbol: symbol,
      decimalDigits: 0,
    );
    return whole.format(value);
  }
}

/// [formatCurrencyAmount] with the display rule: cents drop at or above
/// [wholeMoneyThreshold]. Use on display surfaces only (see
/// [MoneyDisplayFormat.displayMoney]).
String displayCurrencyAmount(double amount, String currency) {
  return moneyFormat(currency).displayMoney(amount);
}

/// Code-prefixed amount ("USD 9,591.00", "MXN 56,344.00") for places that list
/// several currencies side by side — a per-currency breakdown — where a bare
/// "$" is ambiguous about which dollar it is. Always the ISO code, never the
/// idiomatic glyph, so each batch is self-labelling.
String formatCurrencyWithCode(double amount, String currency) {
  final code = currency.toUpperCase();
  return NumberFormat.currency(name: code, symbol: '$code ').format(amount);
}

/// [formatCurrencyWithCode] with the display rule: cents drop at or above
/// [wholeMoneyThreshold]. Use on display surfaces only (see
/// [MoneyDisplayFormat.displayMoney]).
String displayCurrencyWithCode(double amount, String currency) {
  final code = currency.toUpperCase();
  return NumberFormat.currency(name: code, symbol: '$code ')
      .displayMoney(amount);
}
