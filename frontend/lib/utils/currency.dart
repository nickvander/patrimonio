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
