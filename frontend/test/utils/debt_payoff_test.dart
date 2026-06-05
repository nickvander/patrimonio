import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/debt_payoff.dart';

void main() {
  test('avalanche pays less interest than snowball when order differs', () {
    // A: big balance, high APR. B: small balance, low APR.
    // Avalanche targets A (25%), snowball targets B (smallest). Avalanche
    // should retire the expensive debt sooner → less total interest.
    final debts = [
      const Debt(id: 'A', name: 'Card A', balance: 5000, aprAnnual: 0.25),
      const Debt(id: 'B', name: 'Card B', balance: 1000, aprAnnual: 0.08),
    ];
    final av = simulatePayoff(debts, 400, PayoffStrategy.avalanche);
    final sn = simulatePayoff(debts, 400, PayoffStrategy.snowball);

    expect(av.feasible, isTrue);
    expect(sn.feasible, isTrue);
    expect(av.order.first, 'A'); // highest APR first
    expect(sn.order.first, 'B'); // smallest balance first
    expect(av.totalInterest, lessThan(sn.totalInterest));
    expect(av.months, greaterThan(0));
  });

  test('infeasible when the budget cannot cover minimum payments', () {
    final debts = [
      const Debt(id: 'A', name: 'Card A', balance: 5000, aprAnnual: 0.25),
      const Debt(id: 'B', name: 'Card B', balance: 5000, aprAnnual: 0.25),
    ];
    // Minimums alone are ~2% of 10k = $200; a $50 budget can't cover them.
    final r = simulatePayoff(debts, 50, PayoffStrategy.avalanche);
    expect(r.feasible, isFalse);
  });

  test('single debt retires and accrues some interest', () {
    final debts = [
      const Debt(id: 'A', name: 'Card', balance: 1200, aprAnnual: 0.20),
    ];
    final r = simulatePayoff(debts, 300, PayoffStrategy.avalanche);
    expect(r.feasible, isTrue);
    expect(r.months, greaterThan(0));
    expect(r.totalInterest, greaterThan(0));
    // Roughly: $1,200 at $300/mo is ~4-5 months once interest is added.
    expect(r.months, lessThan(8));
  });

  test('no debts is a trivially-complete plan', () {
    final r = simulatePayoff([], 500, PayoffStrategy.snowball);
    expect(r.months, 0);
    expect(r.totalInterest, 0);
    expect(r.feasible, isTrue);
  });

  test('zero-balance debts are ignored', () {
    final debts = [
      const Debt(id: 'A', name: 'Paid', balance: 0, aprAnnual: 0.25),
      const Debt(id: 'B', name: 'Owed', balance: 800, aprAnnual: 0.18),
    ];
    final r = simulatePayoff(debts, 300, PayoffStrategy.avalanche);
    expect(r.order, ['B']);
    expect(r.feasible, isTrue);
  });
}
