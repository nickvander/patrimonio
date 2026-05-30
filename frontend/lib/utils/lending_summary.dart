/// Pure, Flutter-free helpers for the lending tab's summary totals.
///
/// Loans are stored in their own native currency (USD or MXN). The
/// summary card shows a single combined figure in the user's display
/// currency, so each loan's amount has to be converted before summing.
/// The backend's `/loans/summary` endpoint sums naively across
/// currencies (fine for the common single-currency lender); this is the
/// currency-correct path used by the frontend when loans span both.
///
/// Kept in its own file with no Flutter imports so the arithmetic can be
/// unit-tested directly.
library;

/// Convert [amount] from [fromCurrency] into [toCurrency] using the
/// USD→MXN spot rate [usdMxnRate].
///
/// Only USD and MXN are modelled (the app's two currencies). Any
/// unrecognised currency is treated as already being in the target
/// currency (no conversion) — a conservative choice that never inflates
/// a total by a bogus rate.
double convertCurrency(
  double amount,
  String fromCurrency,
  String toCurrency,
  double usdMxnRate,
) {
  final from = fromCurrency.toUpperCase();
  final to = toCurrency.toUpperCase();
  if (from == to) return amount;
  // A non-positive / NaN rate is unusable — fall back to no conversion
  // rather than producing zeros or infinities in the headline figure.
  if (!usdMxnRate.isFinite || usdMxnRate <= 0) return amount;
  if (from == 'USD' && to == 'MXN') return amount * usdMxnRate;
  if (from == 'MXN' && to == 'USD') return amount / usdMxnRate;
  // One side is an unmodelled currency — leave it as-is.
  return amount;
}

/// Sum [field] across [loans], converting each loan from its own
/// `currency` into [targetCurrency]. Missing/!num fields count as 0.
double sumLoansConverted(
  List<dynamic> loans,
  String field,
  String targetCurrency,
  double usdMxnRate,
) {
  var total = 0.0;
  for (final raw in loans) {
    if (raw is! Map) continue;
    final value = (raw[field] as num?)?.toDouble() ?? 0.0;
    if (value == 0.0) continue;
    final currency = (raw['currency'] ?? 'USD').toString();
    total += convertCurrency(value, currency, targetCurrency, usdMxnRate);
  }
  return total;
}

/// True when [loans] span more than one distinct currency — the case
/// where the converted total is meaningfully different from the naive
/// sum, so the UI can surface a "converted at spot" note.
bool loansAreMixedCurrency(List<dynamic> loans) {
  final seen = <String>{};
  for (final raw in loans) {
    if (raw is! Map) continue;
    seen.add((raw['currency'] ?? 'USD').toString().toUpperCase());
    if (seen.length > 1) return true;
  }
  return false;
}
