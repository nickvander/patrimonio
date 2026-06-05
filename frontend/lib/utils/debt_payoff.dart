// Debt-payoff simulation (avalanche vs snowball). Pure + dependency-free so
// it can be unit-tested.
//
// Each month: accrue interest on every balance, pay each debt's minimum
// (max(2% of balance, $25), capped at the balance), then funnel whatever's
// left of the monthly budget at the target debt(s) in strategy order —
// avalanche = highest APR first, snowball = smallest balance first. Freed-up
// minimums roll forward automatically because the whole budget is re-applied
// each month.

class Debt {
  final String id;
  final String name;

  /// Amount owed, USD (positive).
  final double balance;

  /// Nominal annual interest rate, e.g. 0.1999 for 19.99%.
  final double aprAnnual;

  const Debt({
    required this.id,
    required this.name,
    required this.balance,
    required this.aprAnnual,
  });
}

enum PayoffStrategy { avalanche, snowball }

class PayoffResult {
  /// Months to debt-free. Equal to [maxMonths] when not feasible.
  final int months;

  /// Total interest paid over the plan, USD.
  final double totalInterest;

  /// False when the monthly budget can't even cover the minimum payments
  /// (the plan would never retire the debt).
  final bool feasible;

  /// Debt ids in the order they're targeted.
  final List<String> order;

  const PayoffResult({
    required this.months,
    required this.totalInterest,
    required this.feasible,
    required this.order,
  });
}

const double _minRate = 0.02; // 2% of balance
const double _minFloor = 25.0; // or $25, whichever is greater

double _minPayment(double balance) {
  if (balance <= 0) return 0;
  final m = balance * _minRate;
  return (m > _minFloor ? m : _minFloor).clamp(0, balance).toDouble();
}

/// Simulate paying off [debts] with [monthlyBudget] total per month under
/// [strategy]. Returns months-to-free + total interest. Not feasible when the
/// budget can't cover the combined minimum payments.
PayoffResult simulatePayoff(
  List<Debt> debts,
  double monthlyBudget,
  PayoffStrategy strategy, {
  int maxMonths = 1200,
}) {
  final active = debts.where((d) => d.balance > 0).toList();
  if (active.isEmpty) {
    return const PayoffResult(
        months: 0, totalInterest: 0, feasible: true, order: []);
  }

  // Fixed payoff order (standard avalanche/snowball: order set once).
  final order = [...active];
  order.sort((a, b) {
    if (strategy == PayoffStrategy.avalanche) {
      final c = b.aprAnnual.compareTo(a.aprAnnual);
      return c != 0 ? c : a.balance.compareTo(b.balance);
    } else {
      final c = a.balance.compareTo(b.balance);
      return c != 0 ? c : b.aprAnnual.compareTo(a.aprAnnual);
    }
  });

  final bal = {for (final d in active) d.id: d.balance};
  final apr = {for (final d in active) d.id: d.aprAnnual};
  var totalInterest = 0.0;
  var months = 0;

  while (months < maxMonths) {
    final outstanding =
        bal.values.fold(0.0, (s, v) => s + (v > 0 ? v : 0));
    if (outstanding <= 0.005) break;

    // 1) Accrue one month of interest.
    for (final id in bal.keys) {
      if (bal[id]! > 0) {
        final i = bal[id]! * apr[id]! / 12.0;
        bal[id] = bal[id]! + i;
        totalInterest += i;
      }
    }

    // 2) Minimum payments. If the budget can't cover them, the plan can't
    //    make guaranteed progress — report infeasible.
    var budget = monthlyBudget;
    for (final d in order) {
      final b = bal[d.id]!;
      if (b <= 0) continue;
      final m = _minPayment(b);
      if (budget + 1e-9 < m) {
        return PayoffResult(
          months: maxMonths,
          totalInterest: totalInterest,
          feasible: false,
          order: order.map((d) => d.id).toList(),
        );
      }
      final pay = m < b ? m : b;
      bal[d.id] = b - pay;
      budget -= pay;
    }

    // 3) Funnel the remainder at the target order.
    for (final d in order) {
      if (budget <= 0) break;
      final b = bal[d.id]!;
      if (b <= 0) continue;
      final pay = budget < b ? budget : b;
      bal[d.id] = b - pay;
      budget -= pay;
    }

    months++;
  }

  final feasible = months < maxMonths;
  return PayoffResult(
    months: months,
    totalInterest: totalInterest,
    feasible: feasible,
    order: order.map((d) => d.id).toList(),
  );
}
