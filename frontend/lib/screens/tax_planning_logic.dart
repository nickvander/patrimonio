/// Pure, widget-free helpers for the Tax Planning screen.
///
/// Extracted so the year-list derivation and the income/gains → KPI
/// reconciliation can be unit-tested without pumping a widget (and without
/// subclassing ApiService, which drags package:web into the test VM — see
/// MEMORY). The screen calls straight into these.
library;

/// Reconciliation subtotals for the realized-gains section, in USD.
///
/// `taxableGainUsd` must equal the summary's `capital_gains` (both exclude
/// tax-advantaged wrappers); `advantagedGainUsd` is shown separately so a
/// 401(k) rebalance never reads as taxable.
class GainsSubtotals {
  const GainsSubtotals({
    required this.taxableGainUsd,
    required this.advantagedGainUsd,
    required this.taxableCount,
    required this.advantagedCount,
  });

  final double taxableGainUsd;
  final double advantagedGainUsd;
  final int taxableCount;
  final int advantagedCount;
}

/// Build the tax-year dropdown list from the data actually present, newest
/// first. Statement imports reach further back than "this year / last year",
/// so the list is the union of every year seen in income transactions and
/// disposals, plus the current year (always selectable even with no data yet).
///
/// `transactions` rows carry a `date` (ISO `yyyy-MM-dd...`); `disposals` rows
/// carry a `sell_date`. Unparseable/missing dates are ignored.
List<int> deriveTaxYears(
  List<dynamic>? transactions,
  List<dynamic>? disposals, {
  required int currentYear,
}) {
  final years = <int>{currentYear};

  void addFrom(List<dynamic>? rows, String key) {
    if (rows == null) return;
    for (final r in rows) {
      if (r is! Map) continue;
      final raw = r[key];
      final y = _yearOf(raw);
      if (y != null) years.add(y);
    }
  }

  addFrom(transactions, 'date');
  addFrom(disposals, 'sell_date');

  final sorted = years.toList()..sort((a, b) => b.compareTo(a));
  return sorted;
}

/// Parse a leading 4-digit year out of an ISO-ish date string (or a DateTime).
/// Returns null when it can't, so callers can skip bad rows.
int? _yearOf(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.year;
  final s = raw.toString();
  // Fast path: `yyyy-...`. Fall back to a full parse for odd formats.
  if (s.length >= 4) {
    final head = int.tryParse(s.substring(0, 4));
    if (head != null && head > 1900 && head < 3000) return head;
  }
  return DateTime.tryParse(s)?.year;
}

/// Sum the USD income rows behind the income KPI. Each `/tax/transactions`
/// row ships `amount_usd` (converted at its own date's stored FX rate — the
/// same per-row FX the summary's USD ordinary_income is built from), so this
/// reconciles with the headline. Rows missing `amount_usd` fall back to a
/// best-effort raw `amount`.
double sumIncomeUsd(List<dynamic>? transactions) {
  if (transactions == null) return 0;
  var total = 0.0;
  for (final r in transactions) {
    if (r is! Map) continue;
    final usd = (r['amount_usd'] as num?)?.toDouble();
    total += usd ?? ((r['amount'] as num?)?.toDouble() ?? 0);
  }
  return total;
}

/// Split realized disposals into taxable vs tax-advantaged subtotals (USD),
/// summing the signed `gain_usd`. The taxable bucket is what the capital-gains
/// KPI is computed over; the advantaged bucket is surfaced separately.
GainsSubtotals gainsSubtotals(List<dynamic>? disposals) {
  if (disposals == null) {
    return const GainsSubtotals(
      taxableGainUsd: 0,
      advantagedGainUsd: 0,
      taxableCount: 0,
      advantagedCount: 0,
    );
  }
  var taxable = 0.0;
  var advantaged = 0.0;
  var taxableN = 0;
  var advantagedN = 0;
  for (final r in disposals) {
    if (r is! Map) continue;
    final gain = (r['gain_usd'] as num?)?.toDouble() ?? 0;
    if (r['tax_advantaged'] == true) {
      advantaged += gain;
      advantagedN++;
    } else {
      taxable += gain;
      taxableN++;
    }
  }
  return GainsSubtotals(
    taxableGainUsd: taxable,
    advantagedGainUsd: advantaged,
    taxableCount: taxableN,
    advantagedCount: advantagedN,
  );
}

/// Term classification for a disposal's badge: true=Long, false=Short,
/// null=Unknown. Mirrors the backend's nullable `long_term`.
enum DisposalTerm { shortTerm, longTerm, unknown }

DisposalTerm disposalTerm(dynamic longTerm) {
  if (longTerm == true) return DisposalTerm.longTerm;
  if (longTerm == false) return DisposalTerm.shortTerm;
  return DisposalTerm.unknown;
}
