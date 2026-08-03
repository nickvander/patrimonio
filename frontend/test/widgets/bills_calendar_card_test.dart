import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/services/preferences.dart';
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

  /// Every merchant key "Not a bill" POSTed, in order.
  final List<String> ignored = [];

  @override
  Future<Map<String, dynamic>> getRecurringCalendar({
    int days = 30,
    bool forceRefresh = false,
  }) async {
    calls++;
    lastDays = days;
    return result;
  }

  @override
  Future<void> ignoreSubscription(String merchant) async {
    ignored.add(merchant);
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
  String? merchantKey,
}) => {
  'source': source,
  'id': 'id-$description-$dueDate',
  'description': description,
  'account_name': ?accountName,
  'merchant_key': ?merchantKey,
  'amount': amount,
  'currency': currency,
  'amount_usd': amountUsd ?? amount,
  'due_date': dueDate,
  'state': state,
};

/// The two detected clusters' native amounts: Spotify falls on 08-04
/// (i == 1), Netflix on 08-06 (i == 3).
const double _detectedSpotify = -9.99;
const double _detectedNetflix = -15.99;

/// 31 daily projection points. The DECLARED bills alone would run USD
/// 1000 → 800 after 08-04 (rent) → 900 after 08-08 (loan inflow); the two
/// detected charges drag `usd` a further 9.99 (from i == 1) and 15.99
/// (from i == 3) down, and `usd_detected` reports exactly that cumulative
/// part — already INCLUDED in `usd`, per the backend contract. So the
/// detected-subtracted curve a client renders with the toggle off is the
/// plain 1000/800/900 series, which is what the toggle tests assert. MXN
/// flat at 5000 with nothing detected.
List<Map<String, dynamic>> _projection() => [
  for (var i = 0; i <= 30; i++)
    () {
      final d = _today.add(Duration(days: i));
      final declared = i == 0
          ? 1000.0
          : i < 5
          ? 800.0
          : 900.0;
      final detected =
          (i >= 1 ? _detectedSpotify : 0.0) + (i >= 3 ? _detectedNetflix : 0.0);
      return {
        'date':
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}',
        'usd': declared + detected,
        'mxn': 5000.0,
        'usd_detected': detected,
        'mxn_detected': 0.0,
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
    // Detector-inferred: the only occurrence on 08-06 (so hiding it empties
    // that day outright).
    _occurrence(
      description: 'Netflix',
      dueDate: '2026-08-06',
      state: 'upcoming',
      source: 'detected',
      accountName: 'Chase',
      amount: _detectedNetflix,
      merchantKey: 'netflix',
    ),
    // Detector-inferred but sharing 08-04 with the declared Rent — proves
    // the two are separable inside one day's agenda, and that the day's
    // grid marker stays FILLED because a declared bill is also due.
    _occurrence(
      description: 'Spotify',
      dueDate: '2026-08-04',
      state: 'upcoming',
      accountName: 'Chase',
      source: 'detected',
      amount: _detectedSpotify,
      merchantKey: 'spotify',
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

/// Every tick label the projection chart rendered, no-break spaces
/// normalized (compactMoney glues its parts with U+00A0 so a tick can't wrap
/// inside fl_chart's reserved title box).
List<String> _chartTickLabels(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: find.byType(LineChart), matching: find.byType(Text)),
    )
    .map((t) => (t.data ?? '').replaceAll(' ', ' '))
    .where((s) => s.isNotEmpty)
    .toList();

/// The y-values the projection chart is actually plotting. This is the
/// series itself, not a proxy for it — the detected-charges toggle has to
/// change these NUMBERS (`usd - usd_detected`), not merely rebuild.
List<double> _chartCloses(WidgetTester tester) => tester
    .widget<LineChart>(find.byType(LineChart))
    .data
    .lineBarsData
    .first
    .spots
    .map((s) => s.y)
    .toList();

/// Diameters of a day-cell marker: a declared disc, and the wider hollow
/// ring a detected occurrence draws (2026-08-03 legibility pass — the ring
/// was the same 6px box with a 1.5px hairline and read as faint at 1x).
const double _gridDeclaredDot = 6;
const double _gridDetectedDot = _gridDeclaredDot + kBillDetectedSizeBoost;

/// The marker Containers in one day cell, keyed off the only two widths a
/// marker can have (the cell's other Containers are the 44dp selection
/// chrome).
Iterable<Container> _dayDotBoxes(WidgetTester tester, String iso) => tester
    .widgetList<Container>(
      find.descendant(
        of: find.byKey(ValueKey('bc-day-$iso')),
        matching: find.byType(Container),
      ),
    )
    .where(
      (c) =>
          c.constraints?.maxWidth == _gridDeclaredDot ||
          c.constraints?.maxWidth == _gridDetectedDot,
    );

/// The state-dot decorations drawn inside one day cell of the grid — the
/// cell's own today/selected outline never lands in the result.
List<BoxDecoration> _dayDots(WidgetTester tester, String iso) => _dayDotBoxes(
  tester,
  iso,
).map((c) => c.decoration! as BoxDecoration).toList();

/// Flip the "Detected charges" switch and settle.
Future<void> _toggleDetected(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('bc-detected-toggle'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Future<void> _tapDay(WidgetTester tester, String iso) async {
  final day = find.byKey(ValueKey('bc-day-$iso'));
  await tester.ensureVisible(day);
  await tester.tap(day);
  await tester.pumpAndSettle();
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

    testWidgets('billStateDot encodes the source as SHAPE, not as color', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return Column(
                children: [
                  billStateDot(c, state: 'upcoming', detected: false),
                  billStateDot(c, state: 'upcoming', detected: true),
                ],
              );
            },
          ),
        ),
      );
      final dots = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration! as BoxDecoration)
          .toList();
      expect(dots.length, 2);
      final declared = dots[0];
      final detected = dots[1];
      // Declared = filled disc; detected = hollow ring. The distinction
      // survives greyscale and color blindness because it isn't a color
      // distinction at all — both carry the SAME state accent.
      expect(declared.color, ctx.info);
      expect(declared.border, isNull);
      expect(detected.color, isNull);
      expect(detected.border, isNotNull);
      expect(detected.border!.top.color, ctx.info);

      // 2026-08-03 legibility pass. The ring used to be the declared disc's
      // box with a 1.5px hairline — a 1.5px stroke around a 3px hole, which
      // the calendar rig read as "discernible but subtle" at native 1x. It
      // is now a whole-pixel 2px stroke on a marker 2px wider, so it lands
      // on device-pixel boundaries at 1x instead of smearing.
      expect(kBillDetectedRingStroke, 2.0);
      expect(kBillDetectedSizeBoost, 2.0);
      expect(detected.border!.top.width, kBillDetectedRingStroke);

      // Same-hue, shape-only distinction — the ring is WIDER than the disc,
      // never a different color and never a filled marker.
      final boxes = tester.widgetList<Container>(find.byType(Container));
      expect(boxes.first.constraints?.maxWidth, 7.0);
      expect(
        boxes.last.constraints?.maxWidth,
        7.0 + kBillDetectedSizeBoost,
        reason: 'the detected ring is drawn wider than the declared disc',
      );
    });

    // The owner's chosen default. `Preferences` is inert under the test VM
    // (nothing stored), which is exactly the "first run" case: absent must
    // read as SHOWN, so only a literal 'false' hides them.
    test('an unstored preference shows detected charges', () {
      expect(Preferences.getBillsShowDetected(), isTrue);
    });
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

    // The projection y-axis used to go through
    // `NumberFormat.compactSimpleCurrency`, whose table maps MXN to its LOCAL
    // symbol "$" — so a peso curve was labelled "$100K" and read as USD at a
    // glance. Axis ticks go through the house `compactMoney` helper now.
    testWidgets('MXN y-axis ticks carry an unambiguous currency', (
      tester,
    ) async {
      // Spread MXN values so fl_chart places interior ticks (a flat series
      // has nothing to label between min and max).
      final fixture = _calendarFixture()
        ..['projection'] = [
          for (var i = 0; i <= 30; i++)
            {
              'date': _projection()[i]['date'],
              'usd': 1000.0 + i * 200,
              'mxn': 100000.0 + i * 20000,
            },
        ];
      final api = _FakeCalendarApi(fixture);
      await _pump(tester, api);

      await tester.ensureVisible(find.text('MXN'));
      await tester.tap(find.text('MXN'));
      await tester.pumpAndSettle();

      final ticks = _chartTickLabels(tester);
      expect(ticks, isNotEmpty);
      final money = ticks.where((t) => RegExp(r'\d').hasMatch(t)).toList();
      expect(
        money.where((t) => t.startsWith('MXN')),
        isNotEmpty,
        reason: 'peso ticks must name the currency, not borrow "\$": $money',
      );
      expect(
        money.where((t) => t.startsWith('\$')),
        isEmpty,
        reason: 'a peso axis must never render a bare "\$" tick: $money',
      );
    });

    testWidgets('USD y-axis ticks keep the idiomatic "\$" glyph', (
      tester,
    ) async {
      final fixture = _calendarFixture()
        ..['projection'] = [
          for (var i = 0; i <= 30; i++)
            {
              'date': _projection()[i]['date'],
              'usd': 100000.0 + i * 20000,
              'mxn': 2000000.0 + i * 400000,
            },
        ];
      final api = _FakeCalendarApi(fixture);
      await _pump(tester, api);

      final money = _chartTickLabels(
        tester,
      ).where((t) => RegExp(r'\d').hasMatch(t)).toList();
      expect(
        money.where((t) => t.startsWith('\$')),
        isNotEmpty,
        reason: 'USD ticks keep the house glyph: $money',
      );
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

  // Detected recurring charges: the calendar used to read only explicit
  // rules + loan dues, so an owner with zero rules saw nothing but loan
  // repayments. Detected clusters now project too — shown by DEFAULT,
  // marked as INFERRED rather than declared, and hideable behind a
  // persisted toggle.
  group('BillsCalendarCard — detected charges', () {
    testWidgets('detected occurrences are marked and separable from rules', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);

      // 08-04 carries the declared Rent AND the detected Spotify.
      await _tapDay(tester, '2026-08-04');
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('Spotify'), findsOneWidget);

      // Exactly ONE of the two rows claims to be inferred — the mark is
      // per-occurrence, not per-day. (Screen readers get the same claim:
      // the chip carries an explicit semantics label.)
      expect(
        find.bySemanticsLabel(
          'Detected charge, inferred from transaction history',
        ),
        findsOneWidget,
      );
      // "Detected" appears twice: the agenda chip on Spotify + the legend
      // entry that explains the ring. Rent gets neither.
      expect(find.text('Detected'), findsNWidgets(2));

      // Grid markers: 08-06 is detected-only → hollow RING; 08-04 mixes a
      // declared bill in → stays a FILLED disc, so a day with a real rule
      // on it never renders like a day of pure guesses.
      final ringDay = _dayDots(tester, '2026-08-06');
      expect(ringDay, hasLength(1));
      expect(ringDay.single.color, isNull);
      expect(ringDay.single.border, isNotNull);

      final filledDay = _dayDots(tester, '2026-08-04');
      expect(filledDay, hasLength(1));
      expect(filledDay.single.color, isNotNull);
      expect(filledDay.single.border, isNull);

      // Legibility pass: in the GRID (the at-a-glance surface) the ring is
      // an 8px marker with a 2px stroke — a 4px hole — against the declared
      // 6px disc. Both whole numbers, so the ring survives native 1x.
      expect(ringDay.single.border!.top.width, kBillDetectedRingStroke);
      expect(
        _dayDotBoxes(tester, '2026-08-06').single.constraints?.maxWidth,
        _gridDetectedDot,
      );
      expect(
        _dayDotBoxes(tester, '2026-08-04').single.constraints?.maxWidth,
        _gridDeclaredDot,
      );
    });

    testWidgets('toggling off clears them from grid, agenda AND the curve', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);

      // --- default ON ---
      await _tapDay(tester, '2026-08-06');
      expect(find.text('Netflix'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Aug 6, 2026: 1 item'),
        findsOneWidget,
        reason: 'the grid cell counts the detected charge while shown',
      );
      final shown = _chartCloses(tester);
      expect(shown.first, closeTo(1000.0, 0.001));
      expect(
        shown.last,
        closeTo(900.0 + _detectedSpotify + _detectedNetflix, 0.001),
        reason: 'the default curve is the detected-INCLUSIVE `usd` series',
      );

      // --- toggled OFF ---
      await _toggleDetected(tester);

      expect(find.text('Netflix'), findsNothing);
      expect(find.text('Nothing due this day.'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Aug 6, 2026: nothing due'),
        findsOneWidget,
        reason: 'the grid cell must drop the hidden charge too',
      );
      expect(_dayDots(tester, '2026-08-06'), isEmpty);

      // The curve switches to `usd - usd_detected` — real different
      // NUMBERS, not just a rebuild.
      final hidden = _chartCloses(tester);
      expect(hidden.first, closeTo(1000.0, 0.001));
      expect(hidden.last, closeTo(900.0, 0.001));
      expect(hidden[1], closeTo(800.0, 0.001));
      expect(hidden, isNot(equals(shown)));

      // The declared Rent is untouched by the toggle.
      await _tapDay(tester, '2026-08-04');
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('Spotify'), findsNothing);

      // --- back ON ---
      await _toggleDetected(tester);
      expect(find.text('Spotify'), findsOneWidget);
      expect(_chartCloses(tester), equals(shown));
    });

    testWidgets(
      'the FX suggestion is qualified only while detected are hidden',
      (tester) async {
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
        await _pump(tester, api);

        final banner = find.byKey(const ValueKey('bc-fx-banner'));
        final qualifier = find.byKey(const ValueKey('bc-fx-hidden-qualifier'));
        await tester.ensureVisible(banner);
        expect(banner, findsOneWidget);
        expect(
          qualifier,
          findsNothing,
          reason: 'nothing is hidden yet — no qualifier to make',
        );

        await _toggleDetected(tester);

        // The suggestion stays (the backend computes it from the full curve;
        // the risk is real whatever the UI shows) but it now says out loud
        // that some of the bills behind it aren't on screen.
        await tester.ensureVisible(banner);
        expect(banner, findsOneWidget);
        expect(qualifier, findsOneWidget);
        expect(
          find.text('Includes detected charges, which are hidden right now.'),
          findsOneWidget,
        );

        await _toggleDetected(tester);
        expect(find.byKey(const ValueKey('bc-fx-banner')), findsOneWidget);
        expect(qualifier, findsNothing);
      },
    );

    testWidgets('"Not a bill" POSTs the merchant key and refetches', (
      tester,
    ) async {
      final api = _FakeCalendarApi(_calendarFixture());
      await _pump(tester, api);
      expect(api.calls, 1);

      await _tapDay(tester, '2026-08-06');
      // Declared occurrences carry no merchant key and get no action.
      await _tapDay(tester, '2026-08-08'); // the loan due
      expect(find.byIcon(Icons.do_not_disturb_on_outlined), findsNothing);

      await _tapDay(tester, '2026-08-06');
      final action = find.byKey(const ValueKey('bc-not-a-bill-netflix'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // The EXACT key the backend's ignore endpoint expects — not the
      // description, not a re-derived slug.
      expect(api.ignored, equals(['netflix']));
      expect(
        api.calls,
        2,
        reason: 'the calendar refetches so the projection drops it too',
      );
      expect(
        find.textContaining('hidden — it won\'t be projected as a bill'),
        findsOneWidget,
      );
    });

    testWidgets('es-MX: toggle, chip and FX qualifier are localized', (
      tester,
    ) async {
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

      expect(find.text('Cargos detectados'), findsOneWidget);
      await _tapDay(tester, '2026-08-06');
      expect(find.text('Netflix'), findsOneWidget);
      // Chip + legend.
      expect(find.text('Detectado'), findsNWidgets(2));

      await _toggleDetected(tester);
      expect(find.text('Netflix'), findsNothing);
      expect(find.text('Nada por pagar este día.'), findsOneWidget);
      expect(
        find.text('Incluye cargos detectados que ahora están ocultos.'),
        findsOneWidget,
      );
    });
  });
}
