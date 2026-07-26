import 'currency.dart';

/// Lifetime spend at one merchant, expressed in the reporting currency.
///
/// Extracted from the transaction-detail sheet so the conversion is
/// unit-testable: the fold there used to seed with the open transaction's RAW
/// NATIVE amount while converting every sibling, so a reporting-USD view of an
/// MXN 500 charge with two identical priors read "$558.82 across 3" instead of
/// $88.24 — and the overstatement grew with each additional sibling.
///
/// [openConvertedAmount] is the open transaction's amount ALREADY converted
/// to [targetCurrency]; [siblings] are the other rows at the same merchant, in
/// raw API shape (`amount` + `currency`).
double merchantLifetimeTotal({
  required double openConvertedAmount,
  required List<dynamic> siblings,
  required String targetCurrency,
  required double usdMxnRate,
}) {
  return siblings.fold<double>(openConvertedAmount.abs(), (sum, other) {
    final amount = ((other['amount'] as num?)?.toDouble() ?? 0.0).abs();
    final currency = (other['currency'] ?? targetCurrency).toString();
    return sum +
        convertCurrency(
          amount,
          from: currency,
          to: targetCurrency,
          usdMxnRate: usdMxnRate,
        );
  });
}
