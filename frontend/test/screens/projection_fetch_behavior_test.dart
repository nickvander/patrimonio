import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/screens/wealth_projection_screen.dart';

import 'projection_test_host.dart';

// F14: rapid assumption commits are debounced (~300ms) into a single fetch.
// F15: a material (>$1) change to widget.currentNetWorth triggers exactly
// one refetch; float noise (≤$1) does not.

void main() {
  WealthProjectionFetcher countingFetcher(List<double> startBalances) {
    return ({
      required double startBalance,
      required double monthlyContribution,
      required double annualReturnRate,
      required double annualExpenses,
      required double withdrawalRate,
      int years = 30,
      double annualInflationRate = 0.03,
      double returnVolatility = 0.13,
      int? yearsToRetirement,
      int monteCarloTrials = 1000,
      double baristaMonthlyIncome = 0.0,
      double annualTaxDrag = 0.0,
      bool withdrawalGuardrails = false,
      bool mxScenario = false,
      double expensesUsdPortion = 0.0,
      double expensesMxnPortion = 0.0,
      double fxAnnualDrift = 0.0,
      double? usdMxnRate,
    }) async {
      startBalances.add(startBalance);
      return projectionFixture(years: years);
    };
  }

  testWidgets('F14: rapid commits coalesce into one debounced fetch',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final fetches = <double>[];
    await tester
        .pumpWidget(buildProjectionHost(projectionFetcher: countingFetcher(fetches)));
    await tester.pumpAndSettle();
    expect(fetches.length, 1); // initial load

    // Three rapid preset commits, each within the 300ms debounce window.
    for (final label in ['Lean', 'Fat', 'Standard']) {
      final chip = find.widgetWithText(ChoiceChip, label);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(fetches.length, 1); // still only the initial load

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(fetches.length, 2); // exactly one coalesced fetch
  });

  testWidgets('F15: a material net-worth change refetches exactly once; '
      'float noise does not', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final fetches = <double>[];
    final fetcher = countingFetcher(fetches);

    await tester.pumpWidget(buildProjectionHost(
        projectionFetcher: fetcher, currentNetWorth: 500000.0));
    await tester.pumpAndSettle();
    expect(fetches, [500000.0]);

    // Material change (> $1): one refetch from the new balance.
    await tester.pumpWidget(buildProjectionHost(
        projectionFetcher: fetcher, currentNetWorth: 512345.0));
    await tester.pumpAndSettle();
    expect(fetches, [500000.0, 512345.0]);

    // Sub-dollar wiggle: no refetch.
    await tester.pumpWidget(buildProjectionHost(
        projectionFetcher: fetcher, currentNetWorth: 512345.5));
    await tester.pumpAndSettle();
    expect(fetches, [500000.0, 512345.0]);
  });
}
