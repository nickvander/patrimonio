import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/screens/wealth_projection_screen.dart';

import 'projection_test_host.dart';

// "Retire in Mexico" scenario: the toggle swaps the single expense slider for
// a USD/MXN split + FX-drift controls, seeds the peso portion from the
// current expenses at the live rate, sends the scenario params with the
// projection request (and omits them when off), persists through the
// projection_assumptions blob, and renders the dual-currency results panel
// from the backend's mx_scenario block — in en and es-MX.

/// Fetcher that records the scenario params of every call and returns the
/// standard fixture, adding the backend's mx block when the scenario is on.
WealthProjectionFetcher mxAwareFetcher(List<Map<String, Object?>> calls) {
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
    calls.add({
      'mxScenario': mxScenario,
      'usdPortion': expensesUsdPortion,
      'mxnPortion': expensesMxnPortion,
      'drift': fxAnnualDrift,
      'rate': usdMxnRate,
      'annualExpenses': annualExpenses,
    });
    final fix = projectionFixture(years: years);
    if (mxScenario) fix['mx_scenario'] = mxScenarioFixture();
    return fix;
  };
}

Finder _mxSwitch() => find.descendant(
      of: find
          .ancestor(
              of: find.text('Retire in Mexico'),
              matching: find.byType(MergeSemantics))
          .first,
      matching: find.byType(Switch),
    );

Future<void> _toggleOn(WidgetTester tester) async {
  await tester.ensureVisible(_mxSwitch());
  await tester.pumpAndSettle();
  await tester.tap(_mxSwitch());
  // F14 debounce: the commit persists + refetches ~300ms after the flurry.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'default off: no scenario params in the request, no scenario controls, '
      'single expense slider present', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final calls = <Map<String, Object?>>[];
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: mxAwareFetcher(calls),
      usdMxnRate: 17.0,
    ));
    await tester.pumpAndSettle();

    expect(calls.single['mxScenario'], false);
    expect(find.text('Annual expenses'), findsOneWidget);
    expect(find.text('Retire in Mexico'), findsOneWidget); // the toggle row
    expect(find.text('U.S. spending (USD/yr)'), findsNothing);
    expect(find.text('Mexico spending (MXN/yr)'), findsNothing);
    expect(find.text('Retire in Mexico scenario'), findsNothing);
  });

  testWidgets(
      'toggle on: seeds the MXN portion from expenses × live rate, swaps the '
      'expense input for the split, sends scenario params, hides the '
      'lifestyle chips, and renders the dual-currency panel', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final calls = <Map<String, Object?>>[];
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: mxAwareFetcher(calls),
      usdMxnRate: 17.0,
    ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Lean'), findsOneWidget);

    await _toggleOn(tester);

    // Request carries the scenario: all-MXN seed = $40k default × 17.00,
    // rounded to a clean MXN 1,000; the live rate rides along.
    final call = calls.last;
    expect(call['mxScenario'], true);
    expect(call['usdPortion'], 0.0);
    expect(call['mxnPortion'], 680000.0);
    expect(call['drift'], 0.0);
    expect(call['rate'], 17.0);

    // The split replaces the single expense input.
    expect(find.text('Annual expenses'), findsNothing);
    expect(find.text('U.S. spending (USD/yr)'), findsOneWidget);
    expect(find.text('Mexico spending (MXN/yr)'), findsOneWidget);
    expect(find.text('Long-run FX drift (USD/MXN)'), findsOneWidget);
    // Native-currency value labels, ISO-code prefixed.
    expect(
      find.byWidgetPredicate((w) =>
          w is Text && normSpace(w.data ?? '') == 'MXN 680,000'),
      findsOneWidget,
    );
    // The lifestyle presets scale the (now inert) single figure — hidden.
    expect(find.widgetWithText(ChoiceChip, 'Lean'), findsNothing);

    // Dual-currency results panel, straight from the backend block.
    expect(find.text('Retire in Mexico scenario'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w is Text &&
          normSpace(w.data ?? '') == 'USD 1,000,000 · MXN 17,000,000'),
      findsOneWidget,
    );
    // House display rule: cents keep below $10k, drop at/above.
    expect(
      find.byWidgetPredicate((w) =>
          w is Text && normSpace(w.data ?? '') == 'USD 3,300.00 · MXN 56,100'),
      findsOneWidget,
    );
    // gen-l10n orders (now, retire) alphabetically — same as the template.
    expect(
      find.byWidgetPredicate((w) =>
          w is Text &&
          normSpace(w.data ?? '') ==
              'USD/MXN 17.00 today → ≈17.00 at retirement'),
      findsOneWidget,
    );
  });

  testWidgets('es-MX: scenario controls and panel render localized',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final calls = <Map<String, Object?>>[];
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: mxAwareFetcher(calls),
      usdMxnRate: 17.0,
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();

    final toggle = find.descendant(
      of: find
          .ancestor(
              of: find.text('Retiro en México'),
              matching: find.byType(MergeSemantics))
          .first,
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Gasto en EE. UU. (USD/año)'), findsOneWidget);
    expect(find.text('Gasto en México (MXN/año)'), findsOneWidget);
    expect(
        find.text('Deriva cambiaria de largo plazo (USD/MXN)'), findsOneWidget);
    expect(find.text('Escenario de retiro en México'), findsOneWidget);
    expect(find.text('Ingreso en el retiro (mensual)'), findsOneWidget);
    // The two same-typed rate placeholders render in declaration order (the
    // §2 transposition trap): today's rate first, at-retirement second.
    expect(
      find.byWidgetPredicate((w) =>
          w is Text &&
          normSpace(w.data ?? '') == 'USD/MXN 17.00 hoy → ≈17.00 al retiro'),
      findsOneWidget,
    );
  });

  testWidgets('committed toggle persists the scenario fields in the blob',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: mxAwareFetcher(<Map<String, Object?>>[]),
      settingWriter: (key, value) async => writes[key] = value,
      usdMxnRate: 17.0,
    ));
    await tester.pumpAndSettle();

    await _toggleOn(tester);

    final blob = writes['projection_assumptions'] as Map<String, dynamic>?;
    expect(blob, isNotNull);
    expect(blob!['mx_scenario'], true);
    expect(blob['annual_expenses_usd_portion'], 0.0);
    expect(blob['annual_expenses_mxn_portion'], 680000.0);
    expect(blob['fx_annual_drift'], 0.0);
  });

  testWidgets(
      'a restored blob re-activates the scenario with its saved split and '
      'drift (no re-seeding over the user\'s values)', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final calls = <Map<String, Object?>>[];
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: mxAwareFetcher(calls),
      usdMxnRate: 17.0,
      settingReader: (key) async => key == 'projection_assumptions'
          ? {
              'mx_scenario': true,
              'annual_expenses_usd_portion': 12000.0,
              'annual_expenses_mxn_portion': 300000.0,
              'fx_annual_drift': 0.02,
            }
          : null,
    ));
    await tester.pumpAndSettle();

    // The initial fetch already runs the scenario with the restored values.
    expect(calls.last['mxScenario'], true);
    expect(calls.last['usdPortion'], 12000.0);
    expect(calls.last['mxnPortion'], 300000.0);
    expect(calls.last['drift'], 0.02);

    expect(find.text('Annual expenses'), findsNothing);
    expect(
      find.byWidgetPredicate(
          (w) => w is Text && normSpace(w.data ?? '') == 'USD 12,000'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
          (w) => w is Text && normSpace(w.data ?? '') == 'MXN 300,000'),
      findsOneWidget,
    );
    expect(find.text('2.0%'), findsOneWidget); // the restored drift

    // A malformed drift/portion clamps instead of exploding: covered by the
    // hydration clamp test below.
  });

  testWidgets('hydration clamps hostile scenario values', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final calls = <Map<String, Object?>>[];
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: mxAwareFetcher(calls),
      usdMxnRate: 17.0,
      settingReader: (key) async => key == 'projection_assumptions'
          ? {
              'mx_scenario': true,
              'annual_expenses_usd_portion': -5.0,
              'annual_expenses_mxn_portion': 9.0e15,
              'fx_annual_drift': 3.5,
            }
          : null,
    ));
    await tester.pumpAndSettle();

    expect(calls.last['usdPortion'], 0.0); // floored at 0
    expect(calls.last['mxnPortion'], 1000000000.0); // typed cap
    expect(calls.last['drift'], 0.10); // ±10%/yr clamp
  });
}
