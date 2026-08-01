/// Ranking of holdings by a signed USD dollar amount ("dollar movers").
///
/// Shared by the Portfolio signals card's two mover sections:
///  * all-time — ranked on `gain_loss_usd` (cumulative dollar P&L)
///  * today — ranked on `day_change_usd` (dollar move since the last close)
///
/// Ranking by dollars, not %, deliberately: a tiny position can win the
/// percent race while moving the portfolio almost nothing. Holdings whose
/// [field] is null (institution reported no basis, or no day-change data)
/// are skipped rather than treated as 0 — an unknown must not masquerade
/// as a flat performer. Exact zeros land in neither list.
({List<Map<String, dynamic>> gainers, List<Map<String, dynamic>> losers})
topDollarMovers(
  List<dynamic> holdings, {
  required String field,
  int count = 3,
}) {
  final ranked = <Map<String, dynamic>>[];
  for (final h in holdings) {
    if (h is! Map) continue;
    final v = (h[field] as num?)?.toDouble();
    if (v == null) continue;
    ranked.add(h.cast<String, dynamic>());
  }
  ranked.sort((a, b) {
    final va = (a[field] as num).toDouble();
    final vb = (b[field] as num).toDouble();
    return vb.compareTo(va); // descending: biggest dollar gain first
  });
  final gainers = ranked
      .where((h) => (h[field] as num).toDouble() > 0)
      .take(count)
      .toList();
  // Losers: most-negative first. Reverse-iterate the descending list.
  final losers = ranked.reversed
      .where((h) => (h[field] as num).toDouble() < 0)
      .take(count)
      .toList();
  return (gainers: gainers, losers: losers);
}
