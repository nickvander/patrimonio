import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/monthly_cash_flow_card.dart';

/// D2 regression: the headline net figure and its "↑ MXN 6,998.77 vs last
/// month" comparison shared one `Row` with no flex on either child, so at
/// phone width a peso-length comparison (far wider than the dollar one)
/// ran past the card and was clipped by the screen edge — no ellipsis, no
/// wrap, just a cut-off word. The pair is a `Wrap` now: the comparison
/// drops onto its own run instead of overflowing.
void main() {
  // Two months, income 0 so the savings-rate line stays out of the way and
  // the assertions are about the net/comparison pair only. Net =
  // −12,345.67 and the month-over-month delta = 6,998.77 — the figures the
  // live rig reported, in MXN where they are longest.
  const trends = <Map<String, dynamic>>[
    {'month': '2026-06', 'income': 0.0, 'spending': 5346.90},
    {'month': '2026-07', 'income': 0.0, 'spending': 12345.67},
  ];

  Future<void> pumpPhoneCard(WidgetTester tester, Locale locale) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MonthlyCashFlowCard(
            trends: trends,
            conversionFactor: 1.0,
            currencyFormat: moneyFormat('MXN'),
            targetCurrency: 'MXN',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final locale in const [Locale('en'), Locale('es')]) {
    testWidgets('MXN vs-last-month comparison stays inside the card at 390 '
        '(${locale.languageCode})', (tester) async {
      await pumpPhoneCard(tester, locale);

      // No RenderFlex overflow (nor any other layout exception).
      expect(tester.takeException(), isNull);

      final comparison = find.textContaining('MXN 6,998.77');
      expect(comparison, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(comparison);

      // It is painted INSIDE the card — the assertion the old Row failed:
      // a Row child with no flex gets unbounded main-axis constraints, so
      // it laid out at its intrinsic width and painted straight past its
      // parent and off the screen.
      final cardRect = tester.getRect(find.byType(Card));
      final textRect = tester.getRect(comparison);
      expect(
        textRect.right,
        lessThanOrEqualTo(cardRect.right),
        reason: 'comparison line spills past the card edge',
      );
      expect(textRect.left, greaterThanOrEqualTo(cardRect.left));

      // And it is either fully present or *properly* ellipsized — never
      // cut mid-word by a clip. Whenever the string fits the box it was
      // given, it must be rendered whole. (In the test font every glyph is
      // ~1em wide, so the longer es string measures ~360px against the
      // ~350px card line and legitimately takes the ellipsis branch; in
      // Inter it fits with room to spare.)
      final intrinsic = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
      )..layout();
      if (intrinsic.width <= paragraph.size.width + 0.5) {
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: 'comparison line was truncated despite fitting its box',
        );
      }
      intrinsic.dispose();
    });
  }
}
