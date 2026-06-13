import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/screens/tax_planning_logic.dart';

void main() {
  group('deriveTaxYears', () {
    test('unions transaction + disposal years, newest first, with current year',
        () {
      final txns = [
        {'date': '2023-04-01'},
        {'date': '2021-12-31T00:00:00Z'},
      ];
      final disposals = [
        {'sell_date': '2022-06-15'},
        {'sell_date': '2021-02-02'},
      ];
      final years = deriveTaxYears(txns, disposals, currentYear: 2025);
      expect(years, [2025, 2023, 2022, 2021]);
    });

    test('always includes the current year even with no data', () {
      expect(deriveTaxYears(null, null, currentYear: 2025), [2025]);
      expect(deriveTaxYears(const [], const [], currentYear: 2025), [2025]);
    });

    test('does not duplicate the current year when data also contains it', () {
      final txns = [
        {'date': '2025-01-01'},
      ];
      final years = deriveTaxYears(txns, null, currentYear: 2025);
      expect(years, [2025]);
    });

    test('ignores rows with missing or unparseable dates', () {
      final txns = [
        {'date': null},
        {'date': 'not-a-date'},
        {'date': '2020-09-09'},
        {'amount': 5}, // no date key at all
      ];
      final years = deriveTaxYears(txns, null, currentYear: 2025);
      expect(years, [2025, 2020]);
    });

    test('reaches back past "this year / last year" (statement imports)', () {
      final disposals = [
        {'sell_date': '2018-03-03'},
      ];
      final years = deriveTaxYears(null, disposals, currentYear: 2025);
      expect(years, [2025, 2018]);
    });
  });

  group('sumIncomeUsd', () {
    test('sums amount_usd (the per-row FX field the KPI is built from)', () {
      final txns = [
        {'amount_usd': 1000.0, 'amount': 18000.0, 'currency': 'MXN'},
        {'amount_usd': 500.0, 'amount': 500.0, 'currency': 'USD'},
      ];
      // Reconciles with the USD ordinary_income headline, NOT the raw 18,500.
      expect(sumIncomeUsd(txns), 1500.0);
    });

    test('falls back to raw amount when amount_usd is absent', () {
      final txns = [
        {'amount': 250.0},
        {'amount_usd': 100.0},
      ];
      expect(sumIncomeUsd(txns), 350.0);
    });

    test('null/empty yields zero', () {
      expect(sumIncomeUsd(null), 0);
      expect(sumIncomeUsd(const []), 0);
    });
  });

  group('gainsSubtotals', () {
    test('splits taxable vs tax-advantaged and sums signed gains', () {
      final disposals = [
        {'gain_usd': 200.0, 'tax_advantaged': false},
        {'gain_usd': -50.0, 'tax_advantaged': false}, // a loss nets in
        {'gain_usd': 999.0, 'tax_advantaged': true}, // 401k rebalance excluded
      ];
      final s = gainsSubtotals(disposals);
      expect(s.taxableGainUsd, 150.0); // 200 - 50
      expect(s.advantagedGainUsd, 999.0);
      expect(s.taxableCount, 2);
      expect(s.advantagedCount, 1);
    });

    test('taxable subtotal reconciles to the capital-gains KPI (excludes wrappers)',
        () {
      // The capital_gains headline excludes tax-advantaged accounts, so the
      // taxable subtotal must too — this is the on-screen reconciliation.
      final disposals = [
        {'gain_usd': 1000.0, 'tax_advantaged': false},
        {'gain_usd': 5000.0, 'tax_advantaged': true},
      ];
      final s = gainsSubtotals(disposals);
      expect(s.taxableGainUsd, 1000.0);
    });

    test('missing tax_advantaged defaults to taxable', () {
      final disposals = [
        {'gain_usd': 42.0},
      ];
      final s = gainsSubtotals(disposals);
      expect(s.taxableGainUsd, 42.0);
      expect(s.advantagedCount, 0);
    });

    test('null/empty yields zero subtotals', () {
      final s = gainsSubtotals(null);
      expect(s.taxableGainUsd, 0);
      expect(s.advantagedGainUsd, 0);
      expect(s.taxableCount, 0);
      expect(s.advantagedCount, 0);
    });
  });

  group('disposalTerm', () {
    test('maps the nullable long_term flag to a term enum', () {
      expect(disposalTerm(true), DisposalTerm.longTerm);
      expect(disposalTerm(false), DisposalTerm.shortTerm);
      expect(disposalTerm(null), DisposalTerm.unknown);
    });
  });
}
