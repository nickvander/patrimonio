import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/portfolio_card.dart';

/// The signals card's dollar-movers section: the cumulative-P&L list used
/// to ship under a "Top movers (by $)" title that implied intraday. It is
/// now labelled honestly ("Best & worst (all time)") and a real "today"
/// section — fed from the per-row `day_change_usd` the holdings table
/// already renders — sits alongside it, ranked independently.
Map<String, dynamic> _holding(
  String symbol, {
  double value = 10000,
  double? gl,
  double? day,
}) {
  return {
    'symbol': symbol,
    'name': '$symbol Inc',
    'account_name': 'Brokerage',
    'institution_name': 'Vanguard',
    'account_type': 'brokerage',
    'asset_class': 'equity',
    'holding_type': 'equity',
    'currency': 'USD',
    'quantity': 10,
    'price': value / 10,
    'value': value,
    'value_usd': value,
    'gain_loss_usd': gl,
    'gain_loss_pct': gl == null ? null : (gl / value) * 100,
    'day_change_usd': day,
    'day_change_pct': day == null ? null : (day / value) * 100,
  };
}

Widget _host(Widget child, {Locale? locale}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

Widget _signals({Locale? locale}) {
  return _host(
    PortfolioCard(
      section: PortfolioSection.signals,
      portfolioData: {
        'total_value_usd': 30000.0,
        'holdings': [
          // JNJ: big all-time winner, today's dollar loser.
          _holding('JNJ', gl: 5000.0, day: -731.53),
          // TSLA: underwater all-time, today's dollar gainer.
          _holding('TSLA', gl: -2000.0, day: 250.0),
        ],
      },
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(locale: 'en_US', symbol: r'$'),
      targetCurrency: 'USD',
      usdMxnRate: 17.0,
    ),
    locale: locale,
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('en: honest all-time title plus a Today section fed by day data',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_signals());
    await tester.pumpAndSettle();

    // The dishonest title is gone; both time frames are labelled.
    expect(find.textContaining('Top movers (by'), findsNothing);
    expect(find.text('Top movers today (by \$)'), findsOneWidget);
    expect(find.text('Best & worst (all time)'), findsOneWidget);

    // Today ranks day_change_usd: TSLA up, JNJ down.
    expect(find.text('+\$250.00'), findsOneWidget);
    expect(find.text('-\$731.53'), findsOneWidget);
    // All time ranks gain_loss_usd: JNJ up, TSLA down.
    expect(find.text('+\$5,000.00'), findsOneWidget);
    expect(find.text('-\$2,000.00'), findsOneWidget);
  });

  testWidgets('es: both time-frame titles localized', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_signals(locale: const Locale('es')));
    await tester.pumpAndSettle();

    expect(find.text('Mayores movimientos de hoy (por \$)'), findsOneWidget);
    expect(find.text('Mejores y peores (histórico)'), findsOneWidget);
  });

  testWidgets('day data absent: Today section is omitted, all time remains',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(
      PortfolioCard(
        section: PortfolioSection.signals,
        portfolioData: {
          'total_value_usd': 30000.0,
          'holdings': [
            _holding('JNJ', gl: 5000.0, day: null),
          ],
        },
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(locale: 'en_US', symbol: r'$'),
        targetCurrency: 'USD',
        usdMxnRate: 17.0,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Top movers today (by \$)'), findsNothing);
    expect(find.text('Best & worst (all time)'), findsOneWidget);
  });
}
