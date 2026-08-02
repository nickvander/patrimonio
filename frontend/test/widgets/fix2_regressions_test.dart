import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/components/allocation_heatmap.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/accounts_list_widget.dart';
import 'package:patrimonio/widgets/connected_segments.dart';
import 'package:patrimonio/widgets/instrument_detail_sheet.dart';
import 'package:patrimonio/widgets/lot_breakdown_sheet.dart';
import 'package:patrimonio/widgets/portfolio_card.dart';
import 'package:patrimonio/widgets/realized_gains_card.dart';

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
  testWidgets('Day column keeps the minus sign and renders zero as neutral', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        PortfolioCard(
          section: PortfolioSection.holdings,
          portfolioData: {
            'holdings': [
              _holding(
                symbol: 'JNJ',
                account: 'Brokerage',
                value: 51876,
                dayPct: -1.41,
                dayUsd: -731.53,
              ),
              _holding(
                symbol: 'MSFT',
                account: 'Brokerage',
                value: 9000,
                dayPct: 0.0,
                dayUsd: 0.0,
              ),
            ],
          },
          conversionFactor: 1.0,
          currencyFormat: _usd,
          targetCurrency: 'USD',
          usdMxnRate: 17.0,
        ),
      ),
    );
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

  testWidgets('Today pill keeps the minus sign on a down day', (tester) async {
    await tester.pumpWidget(
      _host(
        PortfolioCard(
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
        ),
      ),
    );
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

      await tester.pumpWidget(
        _host(
          PortfolioCard(
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
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('By account'));
      await tester.pumpAndSettle();

      // One HEADER node per account group, announcing account, institution,
      // position count, and subtotal in one go.
      final headerA = find.bySemanticsLabel(
        RegExp(r'Brokerage A, Vanguard, 2 positions, subtotal \$10,000'),
      );
      expect(headerA, findsOneWidget);
      expect(tester.getSemantics(headerA), isSemantics(isHeader: true));
      expect(
        find.bySemanticsLabel(
          RegExp(r'Brokerage B, Vanguard, 1 position, subtotal \$2,000'),
        ),
        findsOneWidget,
      );

      // Grouped rows: one merged node per row WITH the button role + tap.
      final row = find.bySemanticsLabel(RegExp(r'VTI, 10 shares, \$6,000'));
      expect(row, findsOneWidget);
      expect(
        tester.getSemantics(row),
        isSemantics(isButton: true, hasTapAction: true),
      );

      semantics.dispose();
    },
  );

  testWidgets(
    'allocation "Show N more" is its own button node and band tap target '
    'does not cover the expander row',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final filterTaps = <String>[];
      final data = [
        for (var i = 0; i < 6; i++)
          AllocationData(
            'stocks',
            'Fund $i',
            1000.0 + i,
            Colors.teal,
            assetClassKey: 'equity',
          ),
      ];
      await tester.pumpWidget(
        _host(
          AllocationHeatmap(
            data: data,
            conversionFactor: 1.0,
            currencyFormat: _usd,
            onCategorySelected: filterTaps.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The expander has its own labelled button node.
      final expander = find.bySemanticsLabel('Show 2 more');
      expect(expander, findsOneWidget);
      expect(
        tester.getSemantics(expander),
        isSemantics(isButton: true, hasTapAction: true),
      );

      // Mid-row whitespace click on the expander row (well to the right of
      // the visible text) must EXPAND, not apply the band filter.
      final textRect = tester.getRect(find.text('Show 2 more'));
      final bandRect = tester.getRect(find.byType(AllocationHeatmap));
      await tester.tapAt(Offset(bandRect.right - 40, textRect.center.dy));
      await tester.pumpAndSettle();

      expect(
        filterTaps,
        isEmpty,
        reason: 'whitespace click on the expander row applied the filter',
      );
      expect(find.text('Show fewer'), findsOneWidget);
      expect(find.text('Fund 0'), findsOneWidget); // smallest fund now shown

      // The band itself still filters when tapped on its own core.
      await tester.tap(find.text('Stocks'));
      await tester.pumpAndSettle();
      expect(filterTaps, ['asset:equity']);

      semantics.dispose();
    },
  );

  testWidgets('instrument sheet: selected "1Y" chip stays in the semantics '
      'tree and the dividends link node is link-sized', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pumpAndSettle();

    // All four range chips are semantics nodes; the SELECTED one ("1Y" is
    // the default) must not vanish just because its InkWell is disabled.
    for (final chip in ['1M', '3M', '1Y', 'Max']) {
      expect(
        find.bySemanticsLabel(chip),
        findsOneWidget,
        reason: '$chip chip missing from the semantics tree',
      );
    }
    expect(
      tester.getSemantics(find.bySemanticsLabel('1Y')),
      isSemantics(isButton: true, isSelected: true),
    );

    // The dividends-link node is sized to the link, not the full row.
    final linkNode = find.bySemanticsLabel('Dividend details');
    expect(linkNode, findsOneWidget);
    expect(
      tester.getSemantics(linkNode),
      isSemantics(isButton: true, hasTapAction: true),
    );
    final linkWidth = tester.getRect(linkNode).width;
    final sheetWidth = tester.getRect(find.byType(InstrumentDetailSheet)).width;
    expect(
      linkWidth,
      lessThan(sheetWidth / 2),
      reason:
          'link semantics target spans the row '
          '($linkWidth of $sheetWidth px)',
    );

    semantics.dispose();
  });

  testWidgets('account rows carry the "Opens account details" hint', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        AccountsListWidget(
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.bySemanticsLabel(RegExp('Discover it Card'));
    expect(row, findsOneWidget);
    expect(
      tester.getSemantics(row),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        hint: 'Opens account details',
      ),
    );

    semantics.dispose();
  });

  // ── Round-3 guards (WS4): M1 lot-dialog narrow rows, M2 two-row
  //    toolbar, C1 reserved taxable caption. ──────────────────────────

  Map<String, dynamic> lotHolding() => {
    'symbol': 'VOO',
    'name': 'Vanguard S&P 500 ETF',
    'currency': 'USD',
    'quantity': 10.1181,
    'price': 508.0,
    'value': 5140.0,
    'cost_basis_usd': 936.51,
    'lots': [
      {
        // Fixed past date: long-term forever (today only moves forward).
        'acquired_at': '2024-03-01',
        'qty': 10,
        'cost_per_unit': 88.10,
        'currency': 'USD',
        'usd_cost': 881.0,
      },
      {
        // Relative recent date: short-term regardless of when the
        // suite runs. Fractional shares must render in full precision.
        'acquired_at': DateTime.now()
            .subtract(const Duration(days: 30))
            .toIso8601String()
            .substring(0, 10),
        'qty': 0.1181,
        'cost_per_unit': 470.0,
        'currency': 'USD',
        'usd_cost': 55.51,
      },
    ],
  };

  Widget lotDialogHost() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showLotBreakdown(context, lotHolding()),
          child: const Text('open lots'),
        ),
      ),
    ),
  );

  testWidgets('lot dialog collapses to two-line rows on narrow screens '
      '(no headers, fractional shares, inline term chips)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(lotDialogHost());
    await tester.tap(find.text('open lots'));
    await tester.pumpAndSettle();

    // The 6-column headers are gone (they used to wrap as "Acquire d").
    expect(find.text('Acquired'), findsNothing);
    expect(find.text('USD cost'), findsNothing);
    // Line 1: date · qty, with fractional shares at full precision.
    expect(find.textContaining('Mar 1, 2024 · 10 sh'), findsOneWidget);
    expect(find.textContaining('0.1181 sh'), findsOneWidget);
    // Line 2: per-unit → current value · USD cost (10 × $508). Round-3
    // polish dropped the "now" suffix and shrank to 11px so all three
    // amounts share one line at 390px (the "cost $X" pair used to wrap).
    // No pixel-width assertion here: the test font (Ahem) renders every
    // glyph a full em wide, so real-font line fitting can't be measured.
    expect(
      find.textContaining(r'@ $88.10 → $5,080.00 · cost $881.00'),
      findsOneWidget,
    );
    // Term chips render inline with line 1, not squashed away.
    expect(find.text('Long-term'), findsOneWidget);
    expect(find.text('Short-term'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lot dialog keeps the 6-column grid at desktop width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(lotDialogHost());
    await tester.tap(find.text('open lots'));
    await tester.pumpAndSettle();

    // Headers present, and quantities live in their own column (no
    // narrow-layout "sh" composite strings).
    expect(find.text('Acquired'), findsOneWidget);
    expect(find.text('USD cost'), findsOneWidget);
    expect(find.text('0.1181'), findsOneWidget);
    expect(find.textContaining('0.1181 sh'), findsNothing);
    expect(find.text('Long-term'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holdings toolbar becomes two rows under the mobile breakpoint '
      'with the By-account toggle fully visible', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        PortfolioCard(
          section: PortfolioSection.holdings,
          portfolioData: {
            'holdings': [
              _holding(symbol: 'VTI', account: 'Brokerage A', value: 6000),
              _holding(symbol: 'AAPL', account: 'Brokerage B', value: 4000),
            ],
          },
          conversionFactor: 1.0,
          currencyFormat: _usd,
          targetCurrency: 'USD',
          usdMxnRate: 17.0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No RenderFlex overflow at 390px…
    expect(tester.takeException(), isNull);
    // …both toggle segments visible and inside the viewport… (the
    // toggle is the house ConnectedSegments since the restyle)
    expect(find.text('Flat'), findsOneWidget);
    expect(find.text('By account'), findsOneWidget);
    final toggleRect = tester.getRect(find.byType(ConnectedSegments<bool>));
    expect(toggleRect.right, lessThanOrEqualTo(390));
    expect(toggleRect.left, greaterThanOrEqualTo(0));
    // …and the search field sits on its own row above the toggle.
    final searchRect = tester.getRect(find.byType(TextField).first);
    expect(searchRect.bottom, lessThanOrEqualTo(toggleRect.top));
  });

  testWidgets('holdings toolbar stays a single row at desktop width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        PortfolioCard(
          section: PortfolioSection.holdings,
          portfolioData: {
            'holdings': [
              _holding(symbol: 'VTI', account: 'Brokerage A', value: 6000),
            ],
          },
          conversionFactor: 1.0,
          currencyFormat: _usd,
          targetCurrency: 'USD',
          usdMxnRate: 17.0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Search field and toggle share one baseline row on desktop.
    final searchRect = tester.getRect(find.byType(TextField).first);
    final toggleRect = tester.getRect(find.byType(ConnectedSegments<bool>));
    expect(searchRect.center.dy, closeTo(toggleRect.center.dy, 8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('realized-gains caption row is reserved: the all-taxable variant '
      'keeps the exact height of the mixed caption', (tester) async {
    // Wide enough that the mixed caption stays on one line under the test
    // font (Ahem glyphs are square, ~2× wider than production text) — the
    // guarded behavior is the one-line row being reserved, not wrapping.
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic> gains({required bool mixed}) => {
      'summary': {
        'ytd_realized_usd': 500.0,
        'total_realized_usd': 1500.0,
        'taxable_realized_usd': mixed ? 300.0 : 500.0,
      },
      'by_year': [
        {'year': DateTime.now().year, 'realized_usd': 500.0},
      ],
      'disposals': [
        {
          'symbol': 'VOO',
          'sell_date': '2026-03-10',
          'realized_pnl_usd': 200.0,
          'proceeds_usd': 1000.0,
          'long_term': true,
          'tax_advantaged': false,
          'account_name': 'Brokerage',
        },
        {
          'symbol': 'VTI',
          'sell_date': '2026-02-01',
          'realized_pnl_usd': 300.0,
          'proceeds_usd': 900.0,
          'long_term': false,
          'tax_advantaged': mixed,
          'account_name': 'IRA',
        },
      ],
    };

    // Mixed period: the round-2 "Taxable +$X of +$Y…" caption. Distinct
    // keys per pump: the card fetches in initState, so swapping the data
    // must swap the State too.
    await tester.pumpWidget(
      _host(
        RealizedGainsCard(
          key: const ValueKey('mixed'),
          apiService: _GainsApi(gains(mixed: true)),
          conversionFactor: 1.0,
          currencyFormat: _usd,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final mixedCaption = find.textContaining('Taxable');
    expect(mixedCaption, findsOneWidget);
    final mixedHeight = tester.getSize(mixedCaption).height;
    final mixedDividerTop = tester.getTopLeft(find.byType(Divider).first).dy;

    // All-taxable period: the reserved caption replaces the row at the
    // same height — the content below the tiles must not shift.
    await tester.pumpWidget(
      _host(
        RealizedGainsCard(
          key: const ValueKey('all-taxable'),
          apiService: _GainsApi(gains(mixed: false)),
          conversionFactor: 1.0,
          currencyFormat: _usd,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final allCaption = find.text(
      'All realized gains in this period are taxable.',
    );
    expect(allCaption, findsOneWidget);
    expect(tester.getSize(allCaption).height, mixedHeight);
    expect(tester.getTopLeft(find.byType(Divider).first).dy, mixedDividerTop);
  });
}

/// Canned realized-gains payload without touching the network (same
/// subclass seam as lending_tab_layout_test's _FakeApiService).
class _GainsApi extends ApiService {
  final Map<String, dynamic> data;
  _GainsApi(this.data);

  @override
  Future<Map<String, dynamic>> getRealizedGains({
    int? year,
    bool forceRefresh = false,
  }) async => data;
}
