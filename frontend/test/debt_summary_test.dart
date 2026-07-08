import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/debt_payoff.dart';
import 'package:patrimonio/widgets/debt_payoff_card.dart';

void main() {
  group('DebtSummary.from', () {
    test('computes total, balance-weighted APR, and monthly interest', () {
      final debts = <Debt>[
        const Debt(id: 'a', name: 'Card', balance: 6000, aprAnnual: 0.20),
        const Debt(id: 'b', name: 'Loan', balance: 2000, aprAnnual: 0.08),
      ];

      final s = DebtSummary.from(debts);

      // Total owed = 6000 + 2000.
      expect(s.totalOwed, 8000);
      // Weighted APR = (6000*0.20 + 2000*0.08) / 8000 = 1360 / 8000 = 0.17.
      expect(s.weightedApr, closeTo(0.17, 1e-12));
      // Monthly interest = 6000*0.20/12 + 2000*0.08/12 = 100 + 13.333...
      expect(s.monthlyInterest, closeTo(113.3333333, 1e-6));
    });

    test('empty list yields zeros and no divide-by-zero', () {
      final s = DebtSummary.from(const <Debt>[]);
      expect(s.totalOwed, 0);
      expect(s.weightedApr, 0);
      expect(s.monthlyInterest, 0);
    });
  });
}
