import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/services/preferences.dart';
import 'package:patrimonio/widgets/bills_calendar_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistence of the bills calendar's "Detected charges" toggle.
///
/// Lives in its OWN file on purpose: `Preferences`' native backend is inert
/// until `initPrefsStorage()` runs (widget tests never call `main()`), and
/// its cache is a process-global. Waking it up here would leak stored
/// values into every other test in the same file, so the rest of the
/// bills-calendar suite stays in `bills_calendar_card_test.dart` against
/// the inert store, and only this file opts in.

class _FakeCalendarApi extends ApiService {
  _FakeCalendarApi(this.result);

  final Map<String, dynamic> result;

  @override
  Future<Map<String, dynamic>> getRecurringCalendar({
    int days = 30,
    bool forceRefresh = false,
  }) async => result;
}

final DateTime _today = DateTime.utc(2026, 8, 3);

Map<String, dynamic> _fixture() => {
  'from': '2026-07-04',
  'to': '2026-09-02',
  'today': '2026-08-03',
  'days': 30,
  'occurrences': [
    {
      'source': 'recurring',
      'id': 'rule-rent',
      'description': 'Rent',
      'amount': -200.0,
      'currency': 'USD',
      'amount_usd': -200.0,
      'due_date': '2026-08-04',
      'state': 'upcoming',
    },
    {
      'source': 'detected',
      'id': 'netflix::16',
      'merchant_key': 'netflix',
      'description': 'Netflix',
      'amount': -15.99,
      'currency': 'USD',
      'amount_usd': -15.99,
      'due_date': '2026-08-06',
      'state': 'upcoming',
    },
  ],
  'projection': [
    for (var i = 0; i <= 30; i++)
      () {
        final d = _today.add(Duration(days: i));
        final detected = i >= 3 ? -15.99 : 0.0;
        return {
          'date':
              '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}',
          'usd': 1000.0 + detected,
          'mxn': 5000.0,
          'usd_detected': detected,
          'mxn_detected': 0.0,
        };
      }(),
  ],
};

Widget _host(ApiService api) => MaterialApp(
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

Future<void> _pump(WidgetTester tester, ApiService api) async {
  tester.view.physicalSize = const Size(900, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(api));
  await tester.pumpAndSettle();
}

Future<void> _tapDay(WidgetTester tester, String iso) async {
  final day = find.byKey(ValueKey('bc-day-$iso'));
  await tester.ensureVisible(day);
  await tester.tap(day);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Preferences.init();
    // The shared cache survives between tests in this isolate — start every
    // case from the shipped default rather than from the last case's write.
    Preferences.setBillsShowDetected(true);
  });

  testWidgets('the hide-detected choice survives a widget recreation', (
    tester,
  ) async {
    await _pump(tester, _FakeCalendarApi(_fixture()));

    await _tapDay(tester, '2026-08-06');
    expect(find.text('Netflix'), findsOneWidget);

    final toggle = find.byKey(const ValueKey('bc-detected-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('Netflix'), findsNothing);
    expect(Preferences.getBillsShowDetected(), isFalse);

    // Tear the whole card down and build a brand-new one — a fresh State,
    // reading the persisted preference rather than the default.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pump(tester, _FakeCalendarApi(_fixture()));

    await _tapDay(tester, '2026-08-06');
    expect(
      find.text('Netflix'),
      findsNothing,
      reason: 'the reloaded card must honour the stored choice',
    );
    expect(find.text('Nothing due this day.'), findsOneWidget);
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('bc-detected-toggle')))
          .value,
      isFalse,
    );

    // ...and turning it back on persists too.
    final toggleAgain = find.byKey(const ValueKey('bc-detected-toggle'));
    await tester.ensureVisible(toggleAgain);
    await tester.tap(toggleAgain);
    await tester.pumpAndSettle();
    expect(Preferences.getBillsShowDetected(), isTrue);
    expect(find.text('Netflix'), findsOneWidget);
  });

  testWidgets('an unset preference means SHOWN — the owner-chosen default', (
    tester,
  ) async {
    // Nothing stored beyond the setUp normalisation: the switch is on and
    // the detected charge renders without the user doing anything.
    await _pump(tester, _FakeCalendarApi(_fixture()));
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('bc-detected-toggle')))
          .value,
      isTrue,
    );
    await _tapDay(tester, '2026-08-06');
    expect(find.text('Netflix'), findsOneWidget);
  });
}
