import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/portfolio_card.dart';

/// Fix-4 regression guards (mobile holdings identification):
///  1. The holdings-row subtitle truncates the fund legal name FIRST — the
///     account segment (the only part that disambiguates the same fund held
///     in two accounts) stays fully visible on narrow widths.
///  2. The mobile expanded row surfaces Account + Institution as key-value
///     lines with the FULL (soft-wrapped, never ellipsized) value.

const _longFundName =
    'Vanguard Index Funds - Vanguard Total Stock Market Index Fund '
    'Institutional Plus Shares';

Map<String, dynamic> _holding({
  String name = _longFundName,
  String account = 'Roth IRA',
  String institution = 'Fido',
}) {
  return {
    'symbol': 'VTSAX',
    'name': name,
    'account_name': account,
    'institution_name': institution,
    'account_type': 'brokerage',
    'asset_class': 'equity',
    'holding_type': 'equity',
    'currency': 'USD',
    'quantity': 10,
    'price': 100.0,
    'value': 1000.0,
    'value_usd': 1000.0,
    'cost_basis': 800.0,
    'cost_basis_usd': 800.0,
    'gain_loss': 200.0,
    'gain_loss_usd': 200.0,
    'gain_loss_pct': 25.0,
  };
}

Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

NumberFormat get _usd => NumberFormat.currency(locale: 'en_US', symbol: r'$');

Future<void> _pumpHoldings(WidgetTester tester,
    {required Map<String, dynamic> holding}) async {
  await tester.pumpWidget(_host(PortfolioCard(
    section: PortfolioSection.holdings,
    portfolioData: {
      'holdings': [holding],
    },
    conversionFactor: 1.0,
    currencyFormat: _usd,
    targetCurrency: 'USD',
    usdMxnRate: 17.0,
  )));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'subtitle keeps the account fully visible while the long fund name '
      'truncates on a narrow (mobile) width', (tester) async {
    // 520 logical px is below the 560 mobile breakpoint. (The test font's
    // glyphs are ~2x wider than production fonts, so this is the test-font
    // equivalent of a ~390px phone.)
    tester.view.physicalSize = const Size(520, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpHoldings(tester, holding: _holding());

    // Natural (untruncated) width of a subtitle segment, measured with the
    // segment Text's own effective style so the check is independent of the
    // test font's glyph metrics.
    double naturalWidth(Finder f) {
      final text = tester.widget<Text>(f);
      final style =
          DefaultTextStyle.of(tester.element(f)).style.merge(text.style);
      final painter = TextPainter(
        text: TextSpan(text: text.data, style: style),
        textDirection: Directionality.of(tester.element(f)),
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    // The account renders as its own segment, at its full natural width —
    // no ellipsis. Before the fix it was the tail of one end-ellipsized
    // string and never survived a 390px row.
    final acct = find.text('Roth IRA');
    expect(acct, findsOneWidget);
    expect(tester.getSize(acct).width,
        greaterThanOrEqualTo(naturalWidth(acct) - 0.5));

    // The fund legal name is the segment that gave: it's rendered but
    // visually truncated far below its natural width.
    final name = find.text(_longFundName);
    expect(name, findsOneWidget);
    expect(tester.getSize(name).width, lessThan(naturalWidth(name) / 2));

    // The account sits to the RIGHT of the truncated name (order kept:
    // name · institution · account).
    expect(tester.getTopLeft(acct).dx,
        greaterThan(tester.getTopLeft(name).dx));

    // Extreme squeeze: when there isn't legible room for the name at all,
    // it is dropped (with its separator) and the account STILL renders at
    // full width — never the other way around.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    final acctNarrow = find.text('Roth IRA');
    expect(acctNarrow, findsOneWidget);
    expect(tester.getSize(acctNarrow).width,
        greaterThanOrEqualTo(naturalWidth(acctNarrow) - 0.5));
    expect(find.text(_longFundName), findsNothing);
  });

  testWidgets(
      'mobile expanded row lists Account and Institution in full, wrapping '
      'instead of ellipsizing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const longAccount =
        'Nick Van Der Auwermeulen - Roth IRA Brokerage Account - ****9215';
    await _pumpHoldings(
      tester,
      holding: _holding(
        account: longAccount,
        institution: 'Fidelity Investments',
      ),
    );

    // Expand the row.
    await tester.tap(find.text('VTSAX'));
    await tester.pumpAndSettle();

    // Key-value lines exist (reused l10n labels).
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Institution'), findsOneWidget);
    expect(find.text('Fidelity Investments'), findsWidgets);

    // The long account name appears twice: compact subtitle (single line,
    // may clip) + expanded detail line. The detail line shows the FULL
    // value: it soft-wraps onto multiple lines (height > one 13px line)
    // and carries no ellipsis.
    final acctTexts = find.text(longAccount);
    expect(acctTexts, findsNWidgets(2));
    final sizes = acctTexts
        .evaluate()
        .map((e) => (e.renderObject! as RenderBox).size)
        .toList();
    expect(sizes.where((s) => s.height > 20).length, 1,
        reason: 'expanded Account line should wrap onto multiple lines');
    final wrapped = tester
        .widgetList<Text>(acctTexts)
        .where((t) => t.softWrap == true && t.overflow == null);
    expect(wrapped.length, 1);
  });
}
