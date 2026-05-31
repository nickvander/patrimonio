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

import 'dart:math' as math;

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
    // Tolerate non-numeric field values (a stray String must not throw a
    // failed cast) — only a real num counts, anything else is 0.
    final field0 = raw[field];
    final value = field0 is num ? field0.toDouble() : 0.0;
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

/// A client-side projection of a loan's finances, for instant feedback in
/// the add-loan dialog. Approximate by design — the authoritative,
/// penny-accurate schedule is generated server-side in `Decimal` — but the
/// formulas mirror `backend/src/services/loan_schedule.rs` closely enough
/// for a preview (validated against its unit-test values).
class LoanProjection {
  /// The amount lent.
  final double principal;

  /// Projected total interest over the whole term (0 for no-interest loans).
  final double totalInterest;

  /// principal + totalInterest.
  final double totalRepayment;

  /// The recurring payment amount, or null when the loan is open-ended
  /// (no term/frequency) and therefore has no fixed schedule.
  final double? perPayment;

  /// Number of scheduled payments, or null when open-ended.
  final int? periods;

  /// How [perPayment] should be described: 'monthly', 'weekly',
  /// 'balloon' (single payment at maturity), or null when open-ended.
  final String? cadence;

  /// Extra lump principal due at maturity ON TOP of the recurring
  /// [perPayment] — set only for interest-only loans, where the periodic
  /// payment is interest alone and the full principal balloons on the
  /// final installment. Null for every other type (their principal is
  /// already folded into [perPayment] or the single balloon). When set,
  /// the final payment is effectively [perPayment] + [balloonPayment].
  final double? balloonPayment;

  const LoanProjection({
    required this.principal,
    required this.totalInterest,
    required this.totalRepayment,
    this.perPayment,
    this.periods,
    this.cadence,
    this.balloonPayment,
  });
}

/// Payments per year for a given frequency. `lump_sum` returns null
/// (a single payment at maturity, not a periodic cadence).
int? _periodsPerYear(String frequency) {
  switch (frequency) {
    case 'weekly':
      return 52;
    case 'lump_sum':
      return null;
    case 'monthly':
    default:
      return 12;
  }
}

/// Project a loan's finances from raw dialog inputs.
///
/// Returns null only when there isn't enough to say anything (no positive
/// principal). A 0% / 'none' loan still yields a projection with zero
/// interest so the preview is useful for the common interest-free case.
///
/// [ratePercent] is the rate as typed (e.g. 5 for 5%); [ratePeriod] is
/// 'annual' or 'monthly' (a monthly rate is annualised ×12 to match the
/// backend). [interestType] is one of none/simple/amortized/interest_only/
/// compound. [paymentFrequency] is monthly/weekly/lump_sum.
LoanProjection? projectLoan({
  required double? principal,
  required String interestType,
  required double? ratePercent,
  required String ratePeriod,
  required int? termMonths,
  required String paymentFrequency,
}) {
  if (principal == null || principal <= 0) return null;
  final p = principal;
  final rate = ratePercent ?? 0;
  final hasTerm = termMonths != null && termMonths > 0;

  // No interest (or no positive rate): pure principal.
  if (interestType == 'none' || rate <= 0) {
    if (!hasTerm) {
      // Open-ended: repay anytime, no fixed schedule.
      return LoanProjection(
          principal: p, totalInterest: 0, totalRepayment: p);
    }
    final ppy = _periodsPerYear(paymentFrequency);
    if (ppy == null) {
      // Lump sum: one payment of the principal at maturity.
      return LoanProjection(
          principal: p,
          totalInterest: 0,
          totalRepayment: p,
          perPayment: p,
          periods: 1,
          cadence: 'balloon');
    }
    final n = math.max(1, (termMonths / 12.0 * ppy).round());
    return LoanProjection(
        principal: p,
        totalInterest: 0,
        totalRepayment: p,
        perPayment: p / n,
        periods: n,
        cadence: paymentFrequency);
  }

  // Interest-bearing. Normalise to an annual fraction (mirror the backend:
  // a monthly rate_period is annualised ×12 so "1%/month" stays exact).
  final annual = (ratePeriod == 'monthly' ? rate * 12 : rate) / 100.0;
  final months = hasTerm ? termMonths : 12;
  final years = months / 12.0;

  switch (interestType) {
    case 'simple':
      // Backend: interest = principal × annual × years (e.g. $1200 @ 6% /
      // 12mo → $72), spread evenly across the payments.
      final interest = p * annual * years;
      final total = p + interest;
      if (paymentFrequency == 'lump_sum') {
        return LoanProjection(
            principal: p,
            totalInterest: interest,
            totalRepayment: total,
            perPayment: total,
            periods: 1,
            cadence: 'balloon');
      }
      final ppy = _periodsPerYear(paymentFrequency) ?? 12;
      final n = math.max(1, (months / 12.0 * ppy).round());
      return LoanProjection(
          principal: p,
          totalInterest: interest,
          totalRepayment: total,
          perPayment: total / n,
          periods: n,
          cadence: paymentFrequency);

    case 'interest_only':
      // Backend: interest accrues monthly on the full balance; principal is
      // repaid as a balloon at maturity (e.g. $10k @ 12%/6mo → $100/mo +
      // $10k balloon). Periodic payment shown is the monthly interest.
      final perMonthRate = annual / 12.0;
      final n = math.max(1, months);
      final interest = p * perMonthRate * n;
      return LoanProjection(
          principal: p,
          totalInterest: interest,
          totalRepayment: p + interest,
          perPayment: p * perMonthRate,
          periods: n,
          cadence: 'monthly',
          // The recurring payment is interest only; the principal comes
          // back as a balloon on the final installment. Surfacing it keeps
          // the preview honest (n × interest + principal == total to repay).
          balloonPayment: p);

    case 'compound':
      // Backend: single balloon = P(1+i)^n at maturity, compounded monthly
      // (e.g. $1000 @ 10%/24mo → ~$220.39 interest).
      final perMonthRate = annual / 12.0;
      final n = math.max(1, months);
      final grown = p * math.pow(1 + perMonthRate, n).toDouble();
      return LoanProjection(
          principal: p,
          totalInterest: grown - p,
          totalRepayment: grown,
          perPayment: grown,
          periods: 1,
          cadence: 'balloon');

    case 'amortized':
    default:
      // Level-payment amortization: payment = P·r / (1 − (1+r)^−n).
      final ppy = _periodsPerYear(paymentFrequency) ?? 12;
      final n = math.max(1, (months / 12.0 * ppy).round());
      final r = annual / ppy;
      final double payment;
      if (r == 0) {
        payment = p / n;
      } else {
        payment = p * r / (1 - math.pow(1 + r, -n).toDouble());
      }
      final total = payment * n;
      return LoanProjection(
          principal: p,
          totalInterest: total - p,
          totalRepayment: total,
          perPayment: payment,
          periods: n,
          cadence: paymentFrequency == 'lump_sum' ? 'balloon' : paymentFrequency);
  }
}
