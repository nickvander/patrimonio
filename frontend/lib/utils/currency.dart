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
