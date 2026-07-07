import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/components/allocation_heatmap.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/accounts_list_widget.dart';
import 'package:patrimonio/widgets/instrument_detail_sheet.dart';
import 'package:patrimonio/widgets/portfolio_card.dart';

/// Round-2 QA regression guards:
///  1. Negative day changes keep their minus sign (Day column + Today pill)
///     and flat/zero day changes render neutral (no fake "+0.00%").
///  4. The allocation band's "Show N more" expander is its own button node
///     and the band's filter tap target doesn't cover the expander row.
///  5. Grouped "By account" view exposes one header node per account group
///     and grouped rows carry the button role.
///  8. The selected instrument-sheet range chip ("1Y" by default) stays in
///     the semantics tree.

Map<String, dynamic> _holding({
  required String symbol,
  required String account,
  double value = 1000,
  double? dayPct,
  double? dayUsd,
}) {
  return {
    'symbol': symbol,
    'name': '$symbol Inc',
    'account_name': account,
    'institution_name': 'Vanguard',
    'account_type': 'brokerage',
    'asset_class': 'equity',
    'holding_type': 'equity',
    'currency': 'USD',
    'quantity': 10,
    'price': value / 10,
    'value': value,
    'value_usd': value,
    'cost_basis': value * 0.8,
    'cost_basis_usd': value * 0.8,
    'gain_loss': value * 0.2,
    'gain_loss_usd': value * 0.2,
    'gain_loss_pct': 25.0,
    'day_change_pct': dayPct,
    'day_change_usd': dayUsd,
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

void main() {
  testWidgets('Day column keeps the minus sign and renders zero as neutral',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(PortfolioCard(
      section: PortfolioSection.holdings,
      portfolioData: {
        'holdings': [
          _holding(
              symbol: 'JNJ',
              account: 'Brokerage',
              value: 51876,
              dayPct: -1.41,
              dayUsd: -731.53),
          _holding(
              symbol: 'MSFT',
              account: 'Brokerage',
              value: 9000,
              dayPct: 0.0,
              dayUsd: 0.0),
        ],
      },
      conversionFactor: 1.0,
      currencyFormat: _usd,
      targetCurrency: 'USD',
      usdMxnRate: 17.0,
    )));
    await tester.pumpAndSettle();

    // Negative day change: both figures carry the minus sign.
    expect(find.text('-1.41%'), findsOneWidget);
    expect(find.text(r'-$731.53'), findsOneWidget);
    // Flat day change: neutral — no fake "+" and muted (not gain-green).
    expect(find.text('0.00%'), findsOneWidget);
    expect(find.text('+0.00%'), findsNothing);
    final flatText = tester.widget<Text>(find.text('0.00%'));
    final gainText = tester.widget<Text>(find.text('+25.00%').first);
    expect(flatText.style!.color, isNot(gainText.style!.color));
  });

  testWidgets('Today pill keeps the minus sign on a down day',
      (tester) async {
    await tester.pumpWidget(_host(PortfolioCard(
      section: PortfolioSection.summary,
      portfolioData: {
        'holdings': [_holding(symbol: 'JNJ', account: 'Brokerage')],
        'total_value_usd': 380536.20,
        'total_cost_basis_usd': 300000.0,
        'total_gain_loss_usd': 80536.20,
        'day_change_usd': -731.53,
        'day_change_pct': -1.41,
      },
      conversionFactor: 1.0,
      currencyFormat: _usd,
      targetCurrency: 'USD',
      usdMxnRate: 17.0,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining(r'-$731.53 (-1.41%)'), findsOneWidget);
  });

  testWidgets(
      'grouped view exposes account group headers and button-role rows',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(PortfolioCard(
      section: PortfolioSection.holdings,
      portfolioData: {
        'holdings': [
          _holding(symbol: 'VTI', account: 'Brokerage A', value: 6000),
          _holding(symbol: 'AAPL', account: 'Brokerage A', value: 4000),
          _holding(symbol: 'VXUS', account: 'Brokerage B', value: 2000),
        ],
      },
      conversionFactor: 1.0,
      currencyFormat: _usd,
      targetCurrency: 'USD',
      usdMxnRate: 17.0,
      apiService: ApiService(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('By account'));
    await tester.pumpAndSettle();

    // One HEADER node per account group, announcing account, institution,
    // position count, and subtotal in one go.
    final headerA = find.bySemanticsLabel(
        RegExp(r'Brokerage A, Vanguard, 2 positions, subtotal \$10,000'));
    expect(headerA, findsOneWidget);
    expect(
        tester.getSemantics(headerA), isSemantics(isHeader: true));
    expect(
        find.bySemanticsLabel(
            RegExp(r'Brokerage B, Vanguard, 1 position, subtotal \$2,000')),
        findsOneWidget);

    // Grouped rows: one merged node per row WITH the button role + tap.
    final row = find.bySemanticsLabel(RegExp(r'VTI, 10 shares, \$6,000'));
    expect(row, findsOneWidget);
    expect(
        tester.getSemantics(row),
        isSemantics(isButton: true, hasTapAction: true));

    semantics.dispose();
  });

  testWidgets(
      'allocation "Show N more" is its own button node and band tap target '
      'does not cover the expander row', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final filterTaps = <String>[];
    final data = [
      for (var i = 0; i < 6; i++)
        AllocationData('stocks', 'Fund $i', 1000.0 + i, Colors.teal,
            assetClassKey: 'equity'),
    ];
    await tester.pumpWidget(_host(AllocationHeatmap(
      data: data,
      conversionFactor: 1.0,
      currencyFormat: _usd,
      onCategorySelected: filterTaps.add,
    )));
    await tester.pumpAndSettle();

    // The expander has its own labelled button node.
    final expander = find.bySemanticsLabel('Show 2 more');
    expect(expander, findsOneWidget);
    expect(
        tester.getSemantics(expander),
        isSemantics(isButton: true, hasTapAction: true));

    // Mid-row whitespace click on the expander row (well to the right of
    // the visible text) must EXPAND, not apply the band filter.
    final textRect = tester.getRect(find.text('Show 2 more'));
    final bandRect = tester.getRect(find.byType(AllocationHeatmap));
    await tester.tapAt(Offset(bandRect.right - 40, textRect.center.dy));
    await tester.pumpAndSettle();

    expect(filterTaps, isEmpty,
        reason: 'whitespace click on the expander row applied the filter');
    expect(find.text('Show fewer'), findsOneWidget);
    expect(find.text('Fund 0'), findsOneWidget); // smallest fund now shown

    // The band itself still filters when tapped on its own core.
    await tester.tap(find.text('Stocks'));
    await tester.pumpAndSettle();
    expect(filterTaps, ['asset:equity']);

    semantics.dispose();
  });

  testWidgets('instrument sheet: selected "1Y" chip stays in the semantics '
      'tree and the dividends link node is link-sized', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: InstrumentDetailSheet(
          apiService: ApiService(),
          symbol: 'NVDA',
          conversionFactor: 1.0,
          currencyFormat: _usd,
          fetchOverride: (symbol, {range = '1y'}) async => {
            'symbol': 'NVDA',
            'name': 'NVIDIA Corp',
            'currency': 'USD',
            'price': 172.40,
            'quantity': 29.5,
            'value_usd': 5085.80,
            'prices': const [],
            'lots': const [],
            'accounts': const [],
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // All four range chips are semantics nodes; the SELECTED one ("1Y" is
    // the default) must not vanish just because its InkWell is disabled.
    for (final chip in ['1M', '3M', '1Y', 'Max']) {
      expect(find.bySemanticsLabel(chip), findsOneWidget,
          reason: '$chip chip missing from the semantics tree');
    }
    expect(tester.getSemantics(find.bySemanticsLabel('1Y')),
        isSemantics(isButton: true, isSelected: true));

    // The dividends-link node is sized to the link, not the full row.
    final linkNode = find.bySemanticsLabel('Dividend details');
    expect(linkNode, findsOneWidget);
    expect(
        tester.getSemantics(linkNode),
        isSemantics(isButton: true, hasTapAction: true));
    final linkWidth = tester.getRect(linkNode).width;
    final sheetWidth = tester.getRect(find.byType(InstrumentDetailSheet)).width;
    expect(linkWidth, lessThan(sheetWidth / 2),
        reason: 'link semantics target spans the row '
            '($linkWidth of $sheetWidth px)');

    semantics.dispose();
  });

  testWidgets('account rows carry the "Opens account details" hint',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(AccountsListWidget(
      accounts: [
        {
          'id': 'a1',
          'name': 'Discover it Card',
          'account_type': 'credit card',
          'institution_name': 'Discover',
          'current_balance': 25.0,
          'currency': 'USD',
        },
      ],
      conversionFactor: 1.0,
      currencyFormat: _usd,
      targetCurrency: 'USD',
      usdMxnRate: 17.0,
    )));
    await tester.pumpAndSettle();

    final row = find.bySemanticsLabel(RegExp('Discover it Card'));
    expect(row, findsOneWidget);
    expect(
        tester.getSemantics(row),
        isSemantics(
            isButton: true,
            hasTapAction: true,
            hint: 'Opens account details'));

    semantics.dispose();
  });
}
