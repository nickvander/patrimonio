import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/fx_center_sheet.dart';

// Widget tests for the FX center's annual transfer-cost section. Same
// seam pattern as fx_center_sheet_test.dart: every load path is
// overridden (widget tests can't subclass ApiService — package:web
// breaks the test VM — and must not hit the network); the required
// `apiService` instance is real but never called.

Map<String, dynamic> _latestRate() => {
  'base': 'USD',
  'target': 'MXN',
  'rate': 17.5,
  'recorded_at': DateTime.now()
      .subtract(const Duration(hours: 2))
      .toUtc()
      .toIso8601String(),
  'source': 'api',
};

/// Two years, multi-provider, one transfer missing a nearby spot rate —
/// mirrors the backend response shape of /dashboard/fx-transfers/costs.
Map<String, dynamic> _costs() => {
  'spot_window_days': 7,
  'years': [
    {
      'year': 2026,
      'transfer_count': 3,
      'total_moved_usd': 5000.0,
      'moved_by_currency': {'USD': 5000.0},
      'total_cost_usd': 123.45,
      'missing_spot_count': 1,
      'providers': [
        {
          'provider': 'WISE',
          'transfer_count': 2,
          'total_moved_usd': 4200.0,
          'moved_by_currency': {'USD': 4200.0},
          'total_cost_usd': 100.0,
          'missing_spot_count': 0,
        },
        {
          // The backend's keyword-less "unknown" bucket serializes as null.
          'provider': null,
          'transfer_count': 1,
          'total_moved_usd': 800.0,
          'moved_by_currency': {'USD': 800.0},
          'total_cost_usd': 23.45,
          'missing_spot_count': 1,
        },
      ],
    },
    {
      'year': 2025,
      'transfer_count': 1,
      'total_moved_usd': 1000.0,
      'moved_by_currency': {'MXN': 20000.0},
      'total_cost_usd': 25.0,
      'missing_spot_count': 0,
      'providers': [
        {
          'provider': 'REMITLY',
          'transfer_count': 1,
          'total_moved_usd': 1000.0,
          'moved_by_currency': {'MXN': 20000.0},
          'total_cost_usd': 25.0,
          'missing_spot_count': 0,
        },
      ],
    },
  ],
};

Widget _host(Widget sheet, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: sheet),
);

void main() {
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(700, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  FxCenterSheet sheet({Future<Map<String, dynamic>> Function()? costs}) {
    return FxCenterSheet(
      apiService: ApiService(),
      latestRate: _latestRate(),
      fetchHistoryOverride: (_) async => const [],
      refreshOverride: () async => _latestRate(),
      fetchAlertOverride: () async => null,
      saveAlertOverride: (_) async {},
      deleteAlertOverride: () async {},
      fetchCostsOverride: costs ?? () async => _costs(),
    );
  }

  group('FX center transfer-cost section', () {
    testWidgets('renders per-year totals, providers and the caveat (en)', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet()));
      await tester.pumpAndSettle();

      expect(find.text('Transfer costs'), findsOneWidget);
      // Newest-first year rows with their USD cost, money via the house
      // helper (never a hand-built string).
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('2025'), findsOneWidget);
      expect(find.text(formatCurrencyAmount(123.45, 'USD')), findsOneWidget);
      expect(find.text(formatCurrencyAmount(25.0, 'USD')), findsWidgets);
      // Year subtitle: count + moved.
      expect(
        find.text('3 transfers · ${formatCurrencyAmount(5000.0, 'USD')} moved'),
        findsOneWidget,
      );
      // Provider breakdown, null bucket surfaced as "Unknown provider".
      expect(find.text('WISE'), findsOneWidget);
      expect(find.text('REMITLY'), findsOneWidget);
      expect(find.text('Unknown provider'), findsOneWidget);
      // The ±7-day spot caveat is displayed (spec acceptance), driven by
      // the backend's spot_window_days.
      expect(
        find.text(
          'Total cost vs the mid-market rate — nearest stored rate within '
          '±7 days of each transfer.',
        ),
        findsOneWidget,
      );
      // One transfer had no nearby market rate → exclusion note.
      expect(
        find.text(
          '1 transfer had no market rate within the window and is excluded '
          'from the cost',
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders the es-MX strings', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet(), locale: const Locale('es')));
      await tester.pumpAndSettle();

      expect(find.text('Costo de transferencias'), findsOneWidget);
      expect(
        find.text(
          '3 transferencias · ${formatCurrencyAmount(5000.0, 'USD')} movidos',
        ),
        findsOneWidget,
      );
      expect(find.text('Proveedor desconocido'), findsOneWidget);
      expect(
        find.text(
          'Costo total frente al tipo de cambio medio — la tasa registrada '
          'más cercana dentro de ±7 días de cada transferencia.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '1 transferencia sin tipo de cambio cercano; excluida del costo',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the empty state when no transfers are linked', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _host(sheet(costs: () async => {'spot_window_days': 7, 'years': []})),
      );
      await tester.pumpAndSettle();

      expect(find.text('No linked transfers yet'), findsOneWidget);
      expect(find.text('2026'), findsNothing);
    });

    testWidgets('shows the failure state when the report cannot load', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        _host(sheet(costs: () async => throw Exception('boom'))),
      );
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load transfer costs"), findsOneWidget);
    });
  });
}
