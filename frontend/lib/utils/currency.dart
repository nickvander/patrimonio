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

String formatCurrencyAmount(double amount, String currency) {
  final code = currency.toUpperCase();
  return NumberFormat.currency(name: code, symbol: '$code ').format(amount);
}
