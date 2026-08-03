import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/theme_colors.dart';
import 'package:patrimonio/widgets/bills_calendar_card.dart';

/// Bills calendar card: occurrence-state rendering (including the hard
/// requirement that `pending_import` NEVER uses the error color), day-tap
/// agenda, the USD/MXN projection toggle, and FX-prompt visibility — in
/// both en and es-MX. Driven by a faked `getRecurringCalendar` (mixin
/// members are virtual — `extends ApiService` + `@override` is the house
/// fake pattern).

class _FakeCalendarApi extends ApiService {
  _FakeCalendarApi(this.result);

  Map<String, dynamic> result;
  int calls = 0;
  int? lastDays;

  @override
  Future<Map<String, dynamic>> getRecurringCalendar({
    int days = 30,
    bool forceRefresh = false,
  }) async {
    calls++;
    lastDays = days;
    return result;
  }
}

/// Fixed clock: 2026-08-03. The fixture window is ±30 days around it.
final DateTime _today = DateTime.utc(2026, 8, 3);

Map<String, dynamic> _occurrence({
  required String description,
  required String dueDate,
  required String state,
  String source = 'recurring',
  String? accountName,
  double amount = -50.0,
  String currency = 'USD',
  double? amountUsd,
}) => {
  'source': source,
  'id': 'id-$description-$dueDate',
  'description': description,
  'account_name': ?accountName,
  'amount': amount,
  'currency': currency,
  'amount_usd': amountUsd ?? amount,
  'due_date': dueDate,
  'state': state,
};

/// 31 daily projection points: USD 1000 → 800 after 08-04 (rent) → 900
/// after 08-08 (loan inflow); MXN flat at 5000.
List<Map<String, dynamic>> _projection() => [
  for (var i = 0; i <= 30; i++)
    () {
      final d = _today.add(Duration(days: i));
      final usd = i == 0
          ? 1000.0
          : i < 5
          ? 800.0
          : 900.0;
      return {
        'date':
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}',
        'usd': usd,
        'mxn': 5000.0,
      };
    }(),
];

Map<String, dynamic> _calendarFixture({Map<String, dynamic>? fx}) => {
  'from': '2026-07-04',
  'to': '2026-09-02',
  'today': '2026-08-03',
  'days': 30,
  'occurrences': [
    _occurrence(
      description: 'Gym',
      dueDate: '2026-07-24',
      state: 'paid',
      accountName: 'Chase',
    ),
    _occurrence(
      description: 'Rent',
      dueDate: '2026-08-04',
      state: 'upcoming',
      accountName: 'Chase',
      amount: -200.0,
    ),
    _occurrence(
      description: 'Insurance',
      dueDate: '2026-07-19',
      state: 'missed',
      accountName: 'Chase',
      amount: -75.0,
    ),
    _occurrence(
      description: 'CFE',
      dueDate: '2026-07-26',
      state: 'pending_import',
      accountName: 'BBVA',
      amount: -400.0,
      currency: 'MXN',
      amountUsd: -20.0,
    ),
    _occurrence(
      description: 'Jose Ramirez',
      dueDate: '2026-08-08',
      state: 'upcoming',
      source: 'loan',
      amount: 100.0,
    ),
  ],
  'projection': _projection(),
  'fx_transfer_suggestion': ?fx,
};

Widget _host(ApiService api, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Center(
          child: SizedBox(
            width: 600,
            child: BillsCalendarCard(apiService: api, now: _today),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  ApiService api, {
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(900, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(api, locale: locale));
  await tester.pumpAndSettle();
}

void main() {
  group('billStateColor semantics', () {
    testWidgets(
      'pending_import uses the warning accent, never the error color',
      (tester) async {
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        // THE hard requirement (FUTURE.md): a bill that may simply not be
        // imported yet must not render red.
        expect(billStateColor(ctx, 'pending_import'), ctx.warning);
        expect(
          billStateColor(ctx, 'pending_import'),
          isNot(ctx.negative),
          reason: 'pending_import must never share the late/missed red',
        );
        // The four states are pairwise distinct semantics.
        expect(billStateColor(ctx, 'paid'), ctx.positive);
        expect(billStateColor(ctx, 'upcoming'), ctx.info);
        expect(billStateColor(ctx, 'late'), ctx.negative);
        expect(billStateColor(ctx, 'missed'), ctx.negative);
        expect(
          {
            billStateColor(ctx, 'paid'),
            billStateColor(ctx, 'upcoming'),
            billStateColor(ctx, 'missed'),
            billStateColor(ctx, 'pending_import'),
          }.length,
          4,
          reason: 'paid/upcoming/missed/pending_import must be distinct',
        );
      },
    );
  });

  group('BillsCalendarCard (en)', () {
    testWidgets('renders title, legend, and today\'s empty agenda', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);

      expect(api.calls, 1);
      expect(api.lastDays, 30);
      expect(find.text('Bills calendar'), findsOneWidget);
      expect(find.text('Paid'), findsOneWidget);
      expect(find.text('Pending import'), findsOneWidget);
      // Today (2026-08-03) has nothing due — the agenda says so.
      expect(find.text('Nothing due this day.'), findsOneWidget);
    });

    testWidgets('tapping a day shows its occurrences with state labels', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);

      // August 4th carries the upcoming Rent.
      await tester.ensureVisible(
        find.byKey(const ValueKey('bc-day-2026-08-04')),
      );
      await tester.tap(find.byKey(const ValueKey('bc-day-2026-08-04')));
      await tester.pumpAndSettle();
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('Upcoming'), findsWidgets);
      expect(find.text('Nothing due this day.'), findsNothing);

      // The loan due renders with the loan-payment prefix.
      await tester.tap(find.byKey(const ValueKey('bc-day-2026-08-08')));
      await tester.pumpAndSettle();
      expect(find.text('Loan payment — Jose Ramirez'), findsOneWidget);
    });

    testWidgets(
      'pending_import occurrence is explained and never red-labelled',
      (tester) async {
        final api = _FakeCalendarApi(_calendarFixture());
        await _pump(tester, api);

        // CFE (2026-07-26) lives in July — navigate back one month.
        await tester.tap(find.byTooltip('Previous month'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('bc-day-2026-07-26')),
        );
        await tester.tap(find.byKey(const ValueKey('bc-day-2026-07-26')));
        await tester.pumpAndSettle();

        expect(find.text('CFE'), findsOneWidget);
        // Amber treatment: the "awaiting import" subtitle + a tooltip with
        // the full explanation, and the state chip says Pending import —
        // NOT Late / Missed.
        expect(
          find.textContaining('Awaiting statement import'),
          findsOneWidget,
        );
        expect(find.byType(Tooltip), findsWidgets);
        final pendingLabels = find.text('Pending import');
        expect(pendingLabels, findsWidgets);
        // The chip color is the warning accent, not the error color.
        final ctx = tester.element(find.text('CFE'));
        final chip = tester.widgetList<Text>(pendingLabels).last;
        expect(chip.style?.color, ctx.warning);
        expect(chip.style?.color, isNot(ctx.negative));
      },
    );

    testWidgets('currency toggle switches the projection curve', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);

      // Chart data is mirrored into semantics (canvas is excluded); the
      // label carries the selected currency.
      expect(
        find.bySemanticsLabel(RegExp('Projected USD balance')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Projected MXN balance')),
        findsNothing,
      );

      await tester.ensureVisible(find.text('MXN'));
      await tester.tap(find.text('MXN'));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp('Projected MXN balance')),
        findsOneWidget,
      );
    });

    testWidgets('FX prompt renders only when the backend sets the flag', (
      tester,
    ) async {
      // No flag → no banner.
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);
      expect(find.byKey(const ValueKey('bc-fx-banner')), findsNothing);

      // Tear the first host down: re-pumping the same widget shape would
      // preserve the card's State (identical refreshKey → no refetch) and
      // the second fixture would never load.
      await tester.pumpWidget(const SizedBox.shrink());

      // Flag set → informational banner naming both currencies.
      final apiWithFlag = _FakeCalendarApi(
        _calendarFixture(
          fx: {
            'deficit_currency': 'MXN',
            'surplus_currency': 'USD',
            'date': '2026-08-15',
            'shortfall': 400.0,
          },
        ),
      );
      await _pump(tester, apiWithFlag);
      final banner = find.byKey(const ValueKey('bc-fx-banner'));
      await tester.ensureVisible(banner);
      expect(banner, findsOneWidget);
      expect(find.textContaining('Consider moving USD to MXN'), findsOneWidget);
      // The shortfall is the DEFICIT currency's native magnitude.
      expect(find.textContaining('MXN'), findsWidgets);
    });

    testWidgets('hides entirely when there are no occurrences', (tester) async {
      final empty = _calendarFixture()..['occurrences'] = <dynamic>[];
      final api = _FakeCalendarApi(empty);
      await _pump(tester, api);
      expect(find.text('Bills calendar'), findsNothing);
      expect(find.byType(Card), findsNothing);
    });
  });

  group('BillsCalendarCard (es-MX)', () {
    testWidgets('renders localized strings, incl. the pending-import copy', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api, locale: const Locale('es'));

      expect(find.text('Calendario de recibos'), findsOneWidget);
      expect(find.text('Pagado'), findsOneWidget);
      expect(find.text('Nada por pagar este día.'), findsOneWidget);

      await tester.tap(find.byTooltip('Mes anterior'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('bc-day-2026-07-26')),
      );
      await tester.tap(find.byKey(const ValueKey('bc-day-2026-07-26')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('En espera de importación de estado de cuenta'),
        findsOneWidget,
      );
      expect(find.text('Pendiente de importar'), findsWidgets);
    });

    testWidgets('FX prompt is localized', (tester) async {
      final api = _FakeCalendarApi(
        _calendarFixture(
          fx: {
            'deficit_currency': 'MXN',
            'surplus_currency': 'USD',
            'date': '2026-08-15',
            'shortfall': 400.0,
          },
        ),
      );
      await _pump(tester, api, locale: const Locale('es'));
      final banner = find.byKey(const ValueKey('bc-fx-banner'));
      await tester.ensureVisible(banner);
      expect(banner, findsOneWidget);
      expect(find.textContaining('Considera mover USD a MXN'), findsOneWidget);
    });
  });
}
