import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/rules_screen.dart';
import 'package:patrimonio/services/api_service.dart';

// The rules management screen: generated summaries + scope chips, the
// drag-to-reorder round-trip (order is meaning — first match wins), the
// pause toggle, and the delete confirmation, whose copy must say plainly
// that past changes the rule made are KEPT (DEC-028).

class _FakeRulesApi extends ApiService {
  _FakeRulesApi(this.rules);

  List<UserRule> rules;
  List<String>? reorderedIds;
  String? deletedId;
  (String, bool)? toggled;
  bool reorderFails = false;

  @override
  Future<List<UserRule>> getRules() async => rules;

  @override
  Future<Map<String, dynamic>> getDashboardOverview({
    bool forceRefresh = false,
  }) async => {
    'accounts': [
      {'id': 'a1', 'name': 'Perfiles', 'institution_name': 'Banamex'},
    ],
  };

  @override
  Future<List<UserRule>> reorderRules(List<String> orderedIds) async {
    reorderedIds = orderedIds;
    if (reorderFails) throw Exception('reorder blew up');
    final byId = {for (final r in rules) r.id: r};
    return [for (final id in orderedIds) byId[id]!];
  }

  @override
  Future<void> deleteRule(String id) async {
    deletedId = id;
  }

  @override
  Future<UserRule> setRuleActive(String id, bool active) async {
    toggled = (id, active);
    return rules.firstWhere((r) => r.id == id);
  }
}

final _rules = <UserRule>[
  const UserRule(
    id: 'r1',
    matchType: 'contains',
    matchValue: 'OXXO GAS',
    setCategory: 'Transportation',
    accountId: 'a1',
    currency: 'MXN',
    direction: 'outflow',
    amountMin: 100,
    amountMax: 500,
    priority: 0,
    active: true,
  ),
  const UserRule(
    id: 'r2',
    matchType: 'merchant_key',
    matchValue: 'STARBUCKS',
    setDescription: 'Starbucks',
    priority: 10,
    active: false,
  ),
];

Widget _host(ApiService api, {Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RulesScreen(api: api),
    );

String _normSpace(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => _normSpace(t.data ?? ''))
    .join('\n');

void main() {
  testWidgets('en: summaries, scope chips and the paused pill render', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_FakeRulesApi([..._rules])));
    await tester.pumpAndSettle();
    final text = _allText(tester);

    expect(text, contains('Description contains “OXXO GAS”'));
    expect(text, contains('→ Transportation'));
    expect(text, contains('Merchant key is “STARBUCKS”'));
    expect(text, contains('→ rename to “Starbucks”'));

    // Scope chips, in their stable order.
    expect(text, contains('Account: Banamex · Perfiles'));
    expect(text, contains('Currency: MXN'));
    expect(text, contains('Outflows only'));
    expect(text, contains('Amount 100–500'));

    // An inactive rule is labelled, not hidden.
    expect(text, contains('Paused'));
  });

  testWidgets('es: the summary and the intro render in es-MX', (tester) async {
    await tester.pumpWidget(
      _host(_FakeRulesApi([..._rules]), locale: const Locale('es')),
    );
    await tester.pumpAndSettle();
    final text = _allText(tester);

    expect(text, contains('La descripción contiene «OXXO GAS»'));
    expect(text, contains('La clave de comercio es «STARBUCKS»'));
    expect(text, contains('Solo salidas'));
    expect(text, contains('En pausa'));
    expect(
      text,
      contains(
        'Nunca cambian movimientos pasados a menos que revises la vista '
        'previa y confirmes.',
      ),
    );
  });

  testWidgets('empty state explains where rules come from', (tester) async {
    await tester.pumpWidget(_host(_FakeRulesApi([])));
    await tester.pumpAndSettle();
    expect(_allText(tester), contains('No rules yet.'));
  });

  testWidgets('dragging a rule commits the new order', (tester) async {
    final api = _FakeRulesApi([..._rules]);
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    // onReorderItem hands back an ALREADY-adjusted newIndex (unlike the
    // deprecated onReorder) — driving it directly pins that contract.
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(1, 0);
    await tester.pumpAndSettle();

    expect(api.reorderedIds, ['r2', 'r1']);
    expect(
      _allText(tester).indexOf('STARBUCKS'),
      lessThan(_allText(tester).indexOf('OXXO GAS')),
    );
  });

  testWidgets('a failed reorder rolls the list back and says so', (
    tester,
  ) async {
    final api = _FakeRulesApi([..._rules])..reorderFails = true;
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(1, 0);
    await tester.pumpAndSettle();

    expect(
      _allText(tester),
      contains("Couldn't save the new order: reorder blew up"),
    );
    expect(
      _allText(tester).indexOf('OXXO GAS'),
      lessThan(_allText(tester).indexOf('STARBUCKS')),
    );
  });

  testWidgets('the pause switch PATCHes the rule', (tester) async {
    final api = _FakeRulesApi([..._rules]);
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(api.toggled, ('r1', false));
  });

  testWidgets('delete confirm states that past changes are kept (DEC-028)', (
    tester,
  ) async {
    final api = _FakeRulesApi([..._rules]);
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(find.text('Delete this rule?'), findsOneWidget);
    expect(
      _allText(tester),
      contains(
        'New transactions will stop matching it. Past changes made by this '
        'rule are kept — deleting a rule never rewrites your history.',
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.deletedId, 'r1');
    expect(_allText(tester), contains('Rule deleted.'));
  });

  testWidgets('es: delete confirm keeps the same promise in es-MX', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_FakeRulesApi([..._rules]), locale: const Locale('es')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar').last);
    await tester.pumpAndSettle();

    expect(
      _allText(tester),
      contains(
        'Los cambios que la regla ya hizo se conservan: eliminar una regla '
        'nunca reescribe tu historial.',
      ),
    );
  });
}
