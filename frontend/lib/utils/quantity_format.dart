/// Trim trailing zeros and pick a sensible precision based on the
/// magnitude of the share count: integers stay integer, normal lots
/// show 2 decimals, fractional crypto-style holdings keep 4.
String formatQuantity(double q) {
  if (q == q.roundToDouble() && q.abs() < 1e9) {
    return q.toInt().toString();
  }
  if (q.abs() >= 1) {
    return q
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
  return q
      .toStringAsFixed(4)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}
