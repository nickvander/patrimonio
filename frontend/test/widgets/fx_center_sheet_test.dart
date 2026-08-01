import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/fx_center_sheet.dart';

// The sheet takes override test seams (widget tests can't subclass
// ApiService — package:web breaks the test VM — and must not hit the
// network); the required `apiService` instance is real but never called.

Map<String, dynamic> _latestRate({DateTime? recordedAt}) => {
  'base': 'USD',
  'target': 'MXN',
  'rate': 17.5,
  'recorded_at':
      (recordedAt ?? DateTime.now().subtract(const Duration(hours: 2)))
          .toUtc()
          .toIso8601String(),
  'source': 'api',
};

List<Map<String, dynamic>> _history30() => [
  for (var i = 0; i < 10; i++)
    {
      'rate': 17.0 + i * 0.05,
      'timestamp': DateTime.now()
          .subtract(Duration(days: 29 - i * 3))
          .toUtc()
          .toIso8601String(),
    },
];

Widget _host(Widget sheet, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: sheet),
);

void main() {
  // The sheet scrolls inside a 90%-height cap; a tall surface keeps every
  // section on-stage so finders don't need scrolling.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(700, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  FxCenterSheet sheet({
    Map<String, dynamic>? latestRate,
    List<int>? daysLog,
    List<double>? savedThresholds,
    List<bool>? deletes,
    Map<String, dynamic>? alert,
    Map<String, dynamic>? refreshed,
    ValueChanged<Map<String, dynamic>>? onRateChanged,
  }) {
    return FxCenterSheet(
      apiService: ApiService(),
      latestRate: latestRate ?? _latestRate(),
      onRateChanged: onRateChanged,
      fetchHistoryOverride: (days) async {
        daysLog?.add(days);
        return _history30();
      },
      refreshOverride: () async => refreshed ?? _latestRate(),
      fetchAlertOverride: () async => alert,
      saveAlertOverride: (t) async => savedThresholds?.add(t),
      deleteAlertOverride: () async => deletes?.add(true),
    );
  }

  group('FxCenterSheet', () {
    testWidgets(
      'shows rate, VISIBLE relative freshness, chart and sections (en)',
      (tester) async {
        useTallSurface(tester);
        await tester.pumpWidget(_host(sheet()));
        await tester.pumpAndSettle();

        expect(find.text('Exchange rate'), findsOneWidget);
        expect(find.text('17.5000'), findsOneWidget);
        // Relative last-updated time is rendered as plain visible text —
        // spec point (b), not hover/tooltip-only.
        expect(find.text('Updated 2h ago'), findsOneWidget);
        expect(find.text('Converter'), findsOneWidget);
        expect(find.text('Rate alert'), findsOneWidget);
        expect(find.text('30 days'), findsOneWidget);
        expect(find.text('90 days'), findsOneWidget);
      },
    );

    testWidgets('renders the es-MX strings', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet(), locale: const Locale('es')));
      await tester.pumpAndSettle();

      expect(find.text('Tipo de cambio'), findsOneWidget);
      expect(find.text('Actualizado hace 2 h'), findsOneWidget);
      expect(find.text('Convertidor'), findsOneWidget);
      expect(find.text('Alerta de tipo de cambio'), findsOneWidget);
      expect(find.text('30 días'), findsOneWidget);
      expect(find.text('90 días'), findsOneWidget);
    });

    testWidgets('converter links both fields through the current rate', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet()));
      await tester.pumpAndSettle();

      // Seeded: 1 USD -> 17.50 MXN.
      expect(find.widgetWithText(TextField, '17.50'), findsOneWidget);

      // Edit the USD side: 2 -> 35.00.
      await tester.enterText(find.widgetWithText(TextField, '1'), '2');
      await tester.pump();
      expect(find.widgetWithText(TextField, '35.00'), findsOneWidget);

      // Edit the MXN side: 17.5 -> 1.00 back on the USD side.
      await tester.enterText(find.widgetWithText(TextField, '35.00'), '17.5');
      await tester.pump();
      expect(find.widgetWithText(TextField, '1.00'), findsOneWidget);
    });

    testWidgets('range toggle refetches history with the selected window', (
      tester,
    ) async {
      useTallSurface(tester);
      final daysLog = <int>[];
      await tester.pumpWidget(_host(sheet(daysLog: daysLog)));
      await tester.pumpAndSettle();
      expect(daysLog, [30], reason: 'opens on the 30-day window');

      await tester.tap(find.text('90 days'));
      await tester.pumpAndSettle();
      expect(daysLog, [30, 90]);

      // Selecting the already-active range must not refetch.
      await tester.tap(find.text('90 days'));
      await tester.pumpAndSettle();
      expect(daysLog, [30, 90]);
    });

    testWidgets('refresh action pulls a fresh rate and notifies the caller', (
      tester,
    ) async {
      useTallSurface(tester);
      final rateChanges = <Map<String, dynamic>>[];
      final fresh = _latestRate(recordedAt: DateTime.now())..['rate'] = 18.0;
      await tester.pumpWidget(
        _host(sheet(refreshed: fresh, onRateChanged: rateChanges.add)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Refresh rate now'));
      await tester.pumpAndSettle();

      expect(rateChanges, hasLength(1));
      expect(rateChanges.single['rate'], 18.0);
      // Headline re-renders off the fresh rate…
      expect(find.text('18.0000'), findsOneWidget);
      // …and the converter target field follows (1 USD -> 18.00).
      expect(find.widgetWithText(TextField, '18.00'), findsOneWidget);
    });

    testWidgets('saves a valid alert threshold and shows the active line', (
      tester,
    ) async {
      useTallSurface(tester);
      final saved = <double>[];
      await tester.pumpWidget(_host(sheet(savedThresholds: saved)));
      await tester.pumpAndSettle();

      // The alert field is the one under the "Rate alert" section (labeled
      // "USD / MXN" with hint 0.00).
      await tester.enterText(
        find.widgetWithText(TextField, 'USD / MXN'),
        '18.25',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved, [18.25]);
      expect(find.text('Rate alert saved'), findsOneWidget);
      expect(
        find.textContaining('crosses 18.25'),
        findsOneWidget,
        reason: 'active-alert confirmation line appears after save',
      );
    });

    testWidgets('rejects a non-positive threshold client-side', (tester) async {
      useTallSurface(tester);
      final saved = <double>[];
      await tester.pumpWidget(_host(sheet(savedThresholds: saved)));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'USD / MXN'), '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved, isEmpty);
      expect(find.text('Enter a threshold greater than zero'), findsOneWidget);
    });

    testWidgets('existing alert loads into the field and can be removed', (
      tester,
    ) async {
      useTallSurface(tester);
      final deletes = <bool>[];
      await tester.pumpWidget(
        _host(sheet(alert: {'threshold': 17.25}, deletes: deletes)),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '17.25'), findsOneWidget);
      expect(find.textContaining('crosses 17.25'), findsOneWidget);

      await tester.tap(find.text('Remove alert'));
      await tester.pumpAndSettle();

      expect(deletes, [true]);
      expect(find.text('Rate alert removed'), findsOneWidget);
      expect(find.textContaining('crosses 17.25'), findsNothing);
    });
  });
}
