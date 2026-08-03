import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/components/allocation_heatmap.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

/// Regression: at narrow widths the allocation card's header used to
/// ellipsize the "Total: $…" money string MID-DIGITS ("Total: $12,345,6…").
/// Money must never truncate mid-number — the header now mirrors the
/// net-worth hero and shrinks the figure via a FittedBox instead.
///
/// Second regression (owner screenshot, 2026-08-03): the fix above left the
/// title and the total as two equal-flex `Flexible`s in a `spaceBetween` Row,
/// which caps each at HALF the row regardless of what either needs. On a
/// phone the CARD NAME clipped to "Asset distributi…" while the total sat
/// comfortably inside its own half. The title now takes the row's slack, and
/// below the ~420 inner breakpoint the total drops to its own line.
void main() {
  final usd = NumberFormat.currency(locale: 'en_US', symbol: r'$');

  Widget host(double width, {Locale? locale}) {
    return MaterialApp(
      locale: locale,
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

  group('the title is never the thing that truncates', () {
    /// `RenderParagraph.didExceedMaxLines` is true exactly when the text was
    /// clipped/ellipsized — the direct read of "did this string survive".
    bool truncated(WidgetTester tester, Finder text) =>
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

    testWidgets('phone width: the title renders in full, above the total', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(340));
      await tester.pumpAndSettle();

      final title = find.text('Asset distribution');
      final total = find.text('Total: \$1,234,568');
      expect(title, findsOneWidget);
      expect(truncated(tester, title), isFalse);

      // Stacked: the total is on its own line below the title, so it can
      // never compete for the title's width in the first place.
      expect(
        tester.getRect(title).bottom,
        lessThanOrEqualTo(tester.getRect(total).top),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone width, es-MX: the longer title also survives', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(340, locale: const Locale('es')));
      await tester.pumpAndSettle();

      final title = find.text('Distribución de activos');
      expect(title, findsOneWidget);
      expect(truncated(tester, title), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide width: title and total share one line, untruncated', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(1000));
      await tester.pumpAndSettle();

      final title = find.text('Asset distribution');
      final total = find.text('Total: \$1,234,568');
      expect(truncated(tester, title), isFalse);
      // Same line: their vertical bands overlap.
      expect(tester.getRect(title).top, lessThan(tester.getRect(total).bottom));
      expect(tester.getRect(total).top, lessThan(tester.getRect(title).bottom));
      expect(tester.takeException(), isNull);
    });
  });
}
