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

// ---------------------------------------------------------------------------
// T11 — unrealized "what if I sell" helpers
// ---------------------------------------------------------------------------

/// How many days within long-term a short lot must be to get the
/// near-long-term highlight + flip-date callout. The backend already ships
/// `days_until_long_term`; this is the UI threshold the contract documents.
const int kNearLongTermDays = 60;

/// A short lot is "near long-term" when its `days_until_long_term` is a
/// positive value within [kNearLongTermDays]. Already-long-term lots ship a
/// null `days_until_long_term`, so they never highlight; a 0 here would mean it
/// flips today and is treated as not-yet-long, so still eligible — but the
/// backend only emits this field for genuinely short lots, so 0 is unusual.
bool isNearLongTerm(dynamic daysUntilLongTerm) {
  if (daysUntilLongTerm is! num) return false;
  final d = daysUntilLongTerm.toInt();
  return d >= 0 && d <= kNearLongTermDays;
}

/// Split the unrealized `lots` array (already taxable-only from the backend)
/// into short-term and long-term buckets, preserving order. Non-map rows are
/// dropped. `long_term == true` → long bucket, anything else → short bucket
/// (the conservative side; the backend only sets the bool, never null here).
class UnrealizedBuckets {
  const UnrealizedBuckets({required this.shortTerm, required this.longTerm});
  final List<Map<String, dynamic>> shortTerm;
  final List<Map<String, dynamic>> longTerm;
}

UnrealizedBuckets bucketUnrealizedLots(List<dynamic>? lots) {
  final short = <Map<String, dynamic>>[];
  final long = <Map<String, dynamic>>[];
  if (lots != null) {
    for (final r in lots) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      (m['long_term'] == true ? long : short).add(m);
    }
  }
  return UnrealizedBuckets(shortTerm: short, longTerm: long);
}

/// Loss lots that are tax-loss-harvest candidates: a negative
/// `unrealized_gain_usd` AND a present `estimated_tax_savings_usd`. The backend
/// only populates the savings on loss lots, but we guard on both so a row
/// without an estimate never shows a phantom "$0 saved" candidate. Ordered by
/// the largest estimated saving first.
List<Map<String, dynamic>> harvestCandidates(List<dynamic>? lots) {
  final out = <Map<String, dynamic>>[];
  if (lots != null) {
    for (final r in lots) {
      if (r is! Map) continue;
      final gain = (r['unrealized_gain_usd'] as num?)?.toDouble() ?? 0;
      final savings = (r['estimated_tax_savings_usd'] as num?)?.toDouble();
      if (gain < 0 && savings != null) {
        out.add(Map<String, dynamic>.from(r));
      }
    }
  }
  out.sort((a, b) {
    final sa = (a['estimated_tax_savings_usd'] as num?)?.toDouble() ?? 0;
    final sb = (b['estimated_tax_savings_usd'] as num?)?.toDouble() ?? 0;
    return sb.compareTo(sa);
  });
  return out;
}

// ---------------------------------------------------------------------------
// T15 — retirement contribution-room helpers
// ---------------------------------------------------------------------------

/// Progress of a contribution group toward its base limit, for a bar that must
/// read in both themes. `fraction` is clamped to [0, 1] (an over-contribution
/// pins the bar full rather than overflowing it); `remainingRoom` is the
/// backend's figure floored at 0 as a defensive fallback. `over` flags when YTD
/// exceeds the base limit so the UI can tint the bar.
class ContributionProgress {
  const ContributionProgress({
    required this.fraction,
    required this.remainingRoom,
    required this.over,
  });
  final double fraction;
  final double remainingRoom;
  final bool over;
}

ContributionProgress contributionProgress({
  required double ytd,
  required double baseLimit,
  double? remainingRoomFromApi,
}) {
  final room = remainingRoomFromApi ?? (baseLimit - ytd);
  final clampedRoom = room < 0 ? 0.0 : room;
  final frac = baseLimit <= 0 ? 0.0 : (ytd / baseLimit).clamp(0.0, 1.0);
  return ContributionProgress(
    fraction: frac.toDouble(),
    remainingRoom: clampedRoom,
    over: ytd > baseLimit,
  );
}
