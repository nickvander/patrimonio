import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/drill_down_claim.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

/// Generalized drill-down claim banner: per-kind render (bilingual), the
/// createdSince visibility gate, dismiss semantics, and the balance
/// claim's reconciliation line on both sides of the max($1, 5%) gap
/// threshold. (The spike kind is covered by
/// transactions_spike_banner_test.dart.)

/// es strings carry NBSP/narrow-NBSP; normalise so assertions prove
/// placement without pinning the exact codepoint.
String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

/// Local-time anchor: chip/banner label a deterministic "Jul 31".
final DateTime _anchor = DateTime(2026, 7, 31, 19, 59);

String _anchorDay([String locale = 'en']) =>
    DateFormat.MMMd(locale).format(_anchor.toLocal());

/// One row synced AFTER the anchor with [amount] (storage sign
/// convention: positive = inflow), plus one older row that the
/// createdSince filter must hide.
List<Map<String, dynamic>> _rows({required double amount}) => [
  {
    'id': 'new-1',
    'date': '2026-07-28',
    'amount': amount,
    'currency': 'USD',
    'description': 'TX new-1',
    'user_description': 'Row new-1',
    'category': 'GENERAL_MERCHANDISE',
    'account_name': 'Cards',
    'created_at': '2026-08-02T12:00:00Z',
  },
  {
    'id': 'old-1',
    'date': '2026-07-20',
    'amount': -40.0,
    'currency': 'USD',
    'description': 'TX old-1',
    'user_description': 'Row old-1',
    'category': 'GENERAL_MERCHANDISE',
    'account_name': 'Cards',
    'created_at': '2026-07-21T12:00:00Z',
  },
];

Widget _host(
  Locale locale, {
  required List<Map<String, dynamic>> rows,
  DrillDownClaim? claim,
  DateTime? createdSinceSeed,
  VoidCallback? onDismissed,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      primary: false,
      child: TransactionsTab(
        transactions: rows,
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        targetCurrency: 'USD',
        usdMxnRate: 17.0,
        createdSinceSeed: createdSinceSeed ?? _anchor,
        claimBanner: claim,
        onClaimBannerDismissed: onDismissed,
      ),
    ),
  ),
);

/// True when any Text widget's normalised data equals [expected].
bool _hasText(WidgetTester tester, String expected) => tester
    .widgetList<Text>(find.byType(Text))
    .any((t) => _normSpace(t.data ?? '') == _normSpace(expected));

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('count claim (since-visit digest)', () {
    testWidgets('en: restates count + locally-formatted anchor', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: -25.0),
          claim: NewSinceCountClaim(count: 15, anchor: _anchor),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _hasText(tester, '15 new transactions since ${_anchorDay()}'),
        isTrue,
      );
      // Count claims never carry a reconciliation line.
      expect(find.textContaining('of this move'), findsNothing);
    });

    testWidgets('en: singular form', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: -25.0),
          claim: NewSinceCountClaim(count: 1, anchor: _anchor),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _hasText(tester, '1 new transaction since ${_anchorDay()}'),
        isTrue,
      );
    });

    testWidgets('es: full es-MX string', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('es'),
          rows: _rows(amount: -25.0),
          claim: NewSinceCountClaim(count: 15, anchor: _anchor),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _hasText(tester, '15 movimientos nuevos desde ${_anchorDay('es')}'),
        isTrue,
      );
    });
  });

  group('net-worth balance claim', () {
    testWidgets(
      'en: title restates signed amount + pct + anchor; NO reconciliation '
      'line when the visible rows explain the move (gap under threshold)',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        // Claim +$500; the one visible row nets +$500 → gap 0 ≤ max(1, 25).
        await tester.pumpWidget(
          _host(
            const Locale('en'),
            rows: _rows(amount: 500.0),
            claim: BalanceMoveClaim(deltaUsd: 500.0, pct: 3.6, anchor: _anchor),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          _hasText(tester, 'Net worth +\$500.00 (+3.6%) since ${_anchorDay()}'),
          isTrue,
          reason: 'transposed args would render a different exact string',
        );
        expect(find.textContaining('of this move'), findsNothing);
      },
    );

    testWidgets('en: the reconciliation line appears when the gap exceeds '
        'max(\$1, 5% of claim) — visible rows only account for part', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1200, 900));
      // Claim +$500, visible net +$100 → gap $400 > $25 (5% of 500).
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: 100.0),
          claim: BalanceMoveClaim(deltaUsd: 500.0, pct: 3.6, anchor: _anchor),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _hasText(
          tester,
          '1 synced transaction accounts for +\$100.00 of this move; the '
          'rest changed without synced activity (transfers or pending).',
        ),
        isTrue,
      );
    });

    testWidgets('es: title + reconciliation line in es-MX', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('es'),
          rows: _rows(amount: 100.0),
          claim: BalanceMoveClaim(deltaUsd: 500.0, pct: 3.6, anchor: _anchor),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _hasText(
          tester,
          // es-MX percent formatting deliberately matches en (period
          // decimal, no space) — see percent_format_test.dart.
          'El patrimonio cambió +\$500.00 (+3.6%) desde ${_anchorDay('es')}',
        ),
        isTrue,
      );
      expect(
        _hasText(
          tester,
          '1 movimiento sincronizado explica +\$100.00 de este cambio; el '
          'resto se movió sin actividad sincronizada (transferencias o '
          'pendientes).',
        ),
        isTrue,
      );
    });

    testWidgets('hidden once the "New since" chip is removed (gate)', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: 500.0),
          claim: BalanceMoveClaim(deltaUsd: 500.0, pct: 3.6, anchor: _anchor),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Net worth +'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'New since ${_anchorDay()}'),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Net worth +'), findsNothing);
      // The hidden older row is back — the gate cleared a real filter.
      expect(find.text('Row old-1'), findsOneWidget);
    });

    testWidgets('the × fires onClaimBannerDismissed without touching '
        'filters', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      var dismissed = 0;
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: 500.0),
          claim: BalanceMoveClaim(deltaUsd: 500.0, pct: 3.6, anchor: _anchor),
          onDismissed: () => dismissed++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      // The since chip survives — dismissing context must not unfilter.
      expect(
        find.widgetWithText(InputChip, 'New since ${_anchorDay()}'),
        findsOneWidget,
      );
    });
  });

  group('account-move balance claim (largest-move reroute)', () {
    testWidgets('en: names the account, signed amount, anchor', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: 1850.0),
          claim: BalanceMoveClaim(
            deltaUsd: 1850.0,
            anchor: _anchor,
            accountName: 'Fidelity Brokerage',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _hasText(
          tester,
          'Fidelity Brokerage moved +\$1,850.00 since ${_anchorDay()}',
        ),
        isTrue,
      );
      expect(find.textContaining('of this move'), findsNothing);
    });

    testWidgets('es: account-move title', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('es'),
          rows: _rows(amount: 1850.0),
          claim: BalanceMoveClaim(
            deltaUsd: 1850.0,
            anchor: _anchor,
            accountName: 'Fidelity Brokerage',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _hasText(
          tester,
          'Fidelity Brokerage cambió +\$1,850.00 desde ${_anchorDay('es')}',
        ),
        isTrue,
      );
    });

    testWidgets('a negative move renders the − sign and the down icon', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _host(
          const Locale('en'),
          rows: _rows(amount: -1850.0),
          claim: BalanceMoveClaim(
            deltaUsd: -1850.0,
            anchor: _anchor,
            accountName: 'Cards',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _hasText(tester, 'Cards moved −\$1,850.00 since ${_anchorDay()}'),
        isTrue,
      );
      expect(find.byIcon(Icons.trending_down), findsOneWidget);
    });
  });
}
