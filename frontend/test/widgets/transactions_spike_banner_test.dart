import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/drill_down_claim.dart';
import 'package:patrimonio/utils/spending_insight.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

/// The spike comparison banner on the Transactions tab: full-string
/// bilingual render (the 6-placeholder txSpikeBanner key is exactly the
/// kind of gen-l10n alphabetical signature a transposition slips into
/// silently), the category-filter visibility gate, the dismiss ×, and
/// the malformed-month degrade.

/// es money/percent can carry NBSP/narrow-NBSP; normalise so assertions
/// prove placement without pinning the exact codepoint.
String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

/// Six DISTINCT argument values so any transposition breaks the match:
/// category, month label, recent \$612.00, percent 50%, months 6,
/// average \$408.00.
const _insight = SpendingSpikeInsight(
  categoryLabel: 'Gas & electric',
  recentMonth: '2026-03',
  recentUsd: 612.0,
  previousAvgUsd: 408.0,
  trailingAvgUsd: 442.0,
  lookbackMonths: 6,
);

List<Map<String, dynamic>> _txs() => [
  {
    'id': 't1',
    'date': '2026-03-10',
    'amount': -25.0,
    'currency': 'USD',
    'description': 'CFE PAYMENT',
    'user_description': 'Row t1',
    'category_detailed': 'RENT_AND_UTILITIES_GAS_AND_ELECTRICITY',
    'category': 'RENT_AND_UTILITIES',
    'account_name': 'Checking',
  },
];

Widget _host(
  Locale locale, {
  SpendingSpikeInsight? banner,
  String? categorySeed,
  VoidCallback? onDismissed,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      primary: false,
      child: TransactionsTab(
        transactions: _txs(),
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        targetCurrency: 'USD',
        usdMxnRate: 17.0,
        categorySeed: categorySeed,
        // The spike banner is now one constructor of the generalized
        // drill-down claim banner; same gate + dismiss semantics.
        claimBanner: banner == null ? null : SpikeClaim(banner),
        onClaimBannerDismissed: onDismissed,
      ),
    ),
  ),
);

/// True when any Text widget's normalised data equals [expected].
bool _hasText(WidgetTester tester, String expected) => tester
    .widgetList<Text>(find.byType(Text))
    .any((t) => _normSpace(t.data ?? '') == _normSpace(expected));

void main() {
  setUp(() {
    // Wide surface: single-line banner, desktop chip strip.
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('en: renders the full string with every arg in its slot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        const Locale('en'),
        banner: _insight,
        categorySeed: 'Gas & electric',
      ),
    );
    await tester.pumpAndSettle();

    final month = DateFormat.yMMM('en').format(DateTime(2026, 3, 1));
    expect(
      _hasText(
        tester,
        'Gas & electric in $month: \$612.00 spent — 50% above your '
        '6-month average of \$408.00',
      ),
      isTrue,
      reason: 'transposed args would render a different exact string',
    );
  });

  testWidgets('es: renders the full es-MX string (same six args)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        const Locale('es'),
        banner: _insight,
        categorySeed: 'Gas & electric',
      ),
    );
    await tester.pumpAndSettle();

    final month = DateFormat.yMMM('es').format(DateTime(2026, 3, 1));
    expect(
      _hasText(
        tester,
        'Gas & electric en $month: \$612.00 gastados, 50% por encima de '
        'tu promedio de 6 meses de \$408.00',
      ),
      isTrue,
    );
  });

  testWidgets('hidden once the category filter is removed', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        const Locale('en'),
        banner: _insight,
        categorySeed: 'Gas & electric',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.trending_up), findsOneWidget);

    // Remove the category chip — the banner's visibility gate.
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, 'Gas & electric'),
        matching: find.byIcon(Icons.clear),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.trending_up), findsNothing);
  });

  testWidgets('the × fires onSpikeBannerDismissed without touching filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var dismissed = 0;
    await tester.pumpWidget(
      _host(
        const Locale('en'),
        banner: _insight,
        categorySeed: 'Gas & electric',
        onDismissed: () => dismissed++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(dismissed, 1);
    // The category chip survives — dismissing context must not unfilter.
    expect(find.widgetWithText(InputChip, 'Gas & electric'), findsOneWidget);
  });

  testWidgets('absent when recentMonth is malformed (older server)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        const Locale('en'),
        banner: const SpendingSpikeInsight(
          categoryLabel: 'Gas & electric',
          recentMonth: '',
          recentUsd: 612.0,
          previousAvgUsd: 408.0,
          trailingAvgUsd: 442.0,
          lookbackMonths: 6,
        ),
        categorySeed: 'Gas & electric',
      ),
    );
    await tester.pumpAndSettle();
    // The chip applied, but the banner (and its icon) never rendered.
    expect(find.widgetWithText(InputChip, 'Gas & electric'), findsOneWidget);
    expect(find.byIcon(Icons.trending_up), findsNothing);
  });

  testWidgets('narrow width keeps the banner but allows two lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        const Locale('en'),
        banner: _insight,
        categorySeed: 'Gas & electric',
      ),
    );
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(Container),
        matching: find.textContaining('above your'),
      ),
    );
    expect(text.maxLines, 2);
  });
}
