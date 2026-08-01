import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/components/allocation_heatmap.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

/// Regression: at narrow widths the allocation card's header used to
/// ellipsize the "Total: $…" money string MID-DIGITS ("Total: $12,345,6…").
/// Money must never truncate mid-number — the header now mirrors the
/// net-worth hero and shrinks the figure via a FittedBox instead.
void main() {
  final usd = NumberFormat.currency(locale: 'en_US', symbol: r'$');

  Widget host(double width) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: width,
              child: AllocationHeatmap(
                data: [
                  AllocationData(
                    'stocks',
                    'VTI',
                    1234567.89,
                    Colors.teal,
                    assetClassKey: 'equity',
                  ),
                ],
                conversionFactor: 1.0,
                currencyFormat: usd,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('narrow header shrinks the total instead of ellipsizing it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(300));
    await tester.pumpAndSettle();

    // The full money string is present… (displayMoney drops cents at this
    // magnitude, so the header renders the whole-dollar form)
    final totalFinder = find.text('Total: \$1,234,568');
    expect(totalFinder, findsOneWidget);

    // …its Text widget no longer carries the ellipsis overflow…
    final text = tester.widget<Text>(totalFinder);
    expect(
      text.overflow,
      isNot(TextOverflow.ellipsis),
      reason: 'money must never ellipsize mid-digits',
    );

    // …because a FittedBox (scaleDown, like the net-worth hero) wraps it.
    final fitted = find.ancestor(
      of: totalFinder,
      matching: find.byType(FittedBox),
    );
    expect(fitted, findsOneWidget);
    expect(tester.widget<FittedBox>(fitted).fit, BoxFit.scaleDown);

    // And nothing overflowed: pumpAndSettle above would have surfaced a
    // RenderFlex overflow as a test exception if the Row didn't fit.
    expect(tester.takeException(), isNull);
  });
}
