import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/recurring_card.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// Collapse NBSP/NNBSP so es assertions don't pin exact codepoints.
String _normSpace(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => _normSpace(t.data ?? ''))
    .join('\n');

const _rules = [
  {
    'id': 'r1',
    'account_id': 'a1',
    'account_name': 'Checking',
    'description': 'Rent',
    'category': 'Housing',
    'amount': -1200.0,
    'currency': 'USD',
    'cadence': 'monthly',
    'anchor_day': 1,
    'next_due_date': '2026-08-01',
    'effective_next_due': '2026-08-01',
    'active': true,
  },
  {
    'id': 'r2',
    'account_id': 'a2',
    'account_name': 'BBVA',
    'description': 'Luz CFE',
    'category': null,
    'amount': -500.0,
    'currency': 'MXN',
    'cadence': 'monthly',
    'anchor_day': 5,
    'next_due_date': '2026-08-05',
    'effective_next_due': '2026-08-05',
    'active': false,
  },
];

const Map<String, dynamic> _upcoming = {
  'from': '2026-07-23',
  'to': '2026-07-31',
  'items': [
    {
      'rule_id': 'r1',
      'account_id': 'a1',
      'account_name': 'Checking',
      'description': 'Rent',
      'category': 'Housing',
      'amount': -1200.0,
      'currency': 'USD',
      'due_date': '2026-07-28',
      'amount_usd': -1200.0,
    },
    {
      'rule_id': 'r3',
      'account_id': 'a2',
      'account_name': 'BBVA',
      'description': 'Nómina',
      'category': null,
      'amount': 20000.0,
      'currency': 'MXN',
      'due_date': '2026-07-30',
      'amount_usd': 1000.0,
    },
  ],
  'expected_inflows_usd': 1000.0,
  'expected_outflows_usd': 1200.0,
};

RecurringCard _card({
  Map<String, dynamic>? upcoming,
  List<dynamic> rules = _rules,
}) => RecurringCard(
  upcoming: upcoming,
  rules: rules,
  conversionFactor: 1.0,
  targetCurrency: 'USD',
  onToggleRule: (_, _) async {},
  onDeleteRule: (_) async {},
);

void main() {
  testWidgets(
    'en: marks amounts with ISO currency codes and flags them as expected',
    (tester) async {
      await tester.pumpWidget(_wrap(_card(upcoming: _upcoming)));
      await tester.pumpAndSettle();
      final text = _allText(tester);

      expect(text, contains('Recurring'));
      expect(text, contains('Expected'));
      expect(
        text,
        contains(
          'Expected from your recurring rules — not actual transactions.',
        ),
      );
      // Per-row amounts carry their own ISO code (spec: currency-labelled
      // amounts everywhere) — a bare "$" would be ambiguous USD-vs-MXN.
      expect(text, contains('USD 1,200.00'));
      expect(text, contains('MXN 20,000.00'));
      // Header totals: expected in/out, code-labelled.
      expect(text, contains('Expected in'));
      expect(text, contains('Expected out'));
      expect(text, contains('+USD 1,000.00'));
      expect(text, contains('−USD 1,200.00'));
    },
  );

  testWidgets('es: mirrors the copy in Spanish', (tester) async {
    await tester.pumpWidget(
      _wrap(_card(upcoming: _upcoming), locale: const Locale('es')),
    );
    await tester.pumpAndSettle();
    final text = _allText(tester);

    expect(text, contains('Recurrentes'));
    expect(text, contains('Previsto'));
    expect(
      text,
      contains(
        'Previsto según tus reglas recurrentes — no son transacciones reales.',
      ),
    );
    expect(text, contains('Entradas previstas'));
    expect(text, contains('Salidas previstas'));
    // Codes stay ISO in es too.
    expect(text, contains('MXN 20,000.00'));
  });

  testWidgets('empty rules render the discovery hint, not totals', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_card(upcoming: null, rules: const [])));
    await tester.pumpAndSettle();
    final text = _allText(tester);
    expect(text, contains('No recurring rules yet'));
    expect(text, isNot(contains('Expected in')));
  });

  testWidgets('rules with nothing due this period say so', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _card(
          upcoming: const {
            'from': '2026-07-23',
            'to': '2026-07-31',
            'items': [],
            'expected_inflows_usd': 0.0,
            'expected_outflows_usd': 0.0,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_allText(tester), contains('Nothing more expected this period.'));
  });

  testWidgets('Manage opens the rules sheet with pause state and amounts', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_card(upcoming: _upcoming)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    final text = _allText(tester);
    expect(text, contains('Recurring rules'));
    expect(text, contains('Rent'));
    expect(text, contains('Luz CFE'));
    // The paused rule is labelled.
    expect(text, contains('Paused'));
    // Rule amounts are code-labelled too.
    expect(text, contains('MXN 500.00'));
    // One switch per rule; the paused one is off.
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.length, 2);
    expect(switches.where((s) => s.value).length, 1);
  });
}
