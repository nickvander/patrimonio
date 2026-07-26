import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F10: the ~10 assumption fields persist as a `projection_assumptions` JSON
// setting. A stored blob is restored on open (and wins over the tracked-data
// prefill); a malformed blob silently falls back to the defaults; committed
// changes write the blob back.

void main() {
  Future<dynamic> Function(String) readerWith(dynamic assumptions) =>
      (key) async => key == 'projection_assumptions' ? assumptions : null;

  testWidgets('stored assumptions are restored into the sliders and win over '
      'the tracked-data prefill', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      settingReader: readerWith({
        'monthly_contribution': 2500.0,
        'annual_return_rate': 0.09,
        'annual_expenses': 55000.0,
        'projection_years': 40,
        'years_to_retirement': 25,
      }),
      // Adoption-worthy tracked data that must NOT override the saved blob.
      defaultsFetcher: () async => {
        'monthly_contribution': 152.4,
        'annual_expenses': 30000.0,
        'annual_income': 2000.0,
        'months_of_data': 6,
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text(r'$2,500'), findsOneWidget);
    expect(find.text('9.0%'), findsOneWidget);
    expect(find.text(r'$55,000'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('25'), findsOneWidget);
    // No derived-default hints: these are the user's own saved values.
    expect(find.textContaining('months of your data'), findsNothing);
    expect(find.text('Estimate — adjust to your spending'), findsNothing);
  });

  testWidgets('a malformed blob silently keeps the defaults', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      settingReader: readerWith('not json at all'),
    ));
    await tester.pumpAndSettle();

    expect(find.text(r'$1,000'), findsOneWidget); // default contribution
    expect(find.text('7.0%'), findsOneWidget); // default return
    expect(find.text(r'$40,000'), findsOneWidget); // default expenses
  });

  testWidgets('a committed change writes the assumptions blob',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      settingWriter: (key, value) async => writes[key] = value,
    ));
    await tester.pumpAndSettle();

    // Committing a lifestyle preset is an assumption change.
    final lean = find.widgetWithText(ChoiceChip, 'Lean');
    await tester.ensureVisible(lean);
    await tester.pumpAndSettle();
    await tester.tap(lean);
    // F14: the commit is debounced ~300ms before persisting + fetching.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final blob = writes['projection_assumptions'] as Map<String, dynamic>?;
    expect(blob, isNotNull);
    expect(blob!['annual_expenses'], 28000.0); // Lean = 0.7 × $40k default
    expect(blob['monthly_contribution'], 1000.0);
    expect(blob['withdrawal_guardrails'], false);
  });

  // A failed READ used to be indistinguishable from "nothing saved": the
  // screen fell back to derived defaults and the next committed change
  // persisted those defaults OVER the user's real scenario. A transient
  // network blip on open must not be able to destroy saved assumptions.
  testWidgets('a read failure does not let defaults overwrite saved values',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    var reads = 0;
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      settingReader: (key) async {
        reads++;
        throw Exception('network down');
      },
      settingWriter: (key, value) async => writes[key] = value,
    ));
    await tester.pumpAndSettle();

    final lean = find.widgetWithText(ChoiceChip, 'Lean');
    await tester.ensureVisible(lean);
    await tester.pumpAndSettle();
    await tester.tap(lean);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(writes, isEmpty,
        reason: 'must not overwrite a scenario we failed to read');
    expect(reads, greaterThan(1),
        reason: 'it should retry the read before deciding to write');
  });

  // …but once the read succeeds and confirms there is genuinely nothing
  // stored, writing is correct again.
  testWidgets('a recovered read unblocks persistence', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    var reads = 0;
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      settingReader: (key) async {
        reads++;
        if (reads == 1) throw Exception('network down');
        return null; // nothing saved
      },
      settingWriter: (key, value) async => writes[key] = value,
    ));
    await tester.pumpAndSettle();

    // Two different presets: the first commit spends its turn re-reading,
    // the second is the one that must actually persist.
    for (final label in ['Lean', 'Fat']) {
      final chip = find.widgetWithText(ChoiceChip, label);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }

    expect(writes['projection_assumptions'], isNotNull,
        reason: 'the retried read confirmed nothing was stored');
  });
}
