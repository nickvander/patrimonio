import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/account_lookup.dart';

/// The largest-move reroute's account resolution + panel-vs-fallback
/// decision (dashboard `_openAccountMovePanel` delegates here).
void main() {
  const accounts = [
    {'id': 'acc-1', 'name': 'Cards', 'current_balance': 100.0},
    {'id': 'acc-2', 'name': 'Checking'},
  ];

  group('findAccountById', () {
    test('resolves a present id to its (copied) account map', () {
      final found = findAccountById(accounts, 'acc-1');
      expect(found, isNotNull);
      expect(found!['name'], 'Cards');
      // A copy, not the shared instance — callers may annotate it.
      expect(identical(found, accounts.first), isFalse);
    });

    test('missing id (archived account) → null', () {
      expect(findAccountById(accounts, 'acc-gone'), isNull);
    });

    test('empty id and malformed rows → null, no crash', () {
      expect(findAccountById(accounts, ''), isNull);
      expect(findAccountById(['not-a-map', 42], 'acc-1'), isNull);
    });
  });

  group('routeAccountMoveJump', () {
    test('resolvable id opens the panel with the account; no fallback', () {
      Map<String, dynamic>? opened;
      var fellBack = false;
      routeAccountMoveJump(
        accounts: accounts,
        accountId: 'acc-2',
        openPanel: (a) => opened = a,
        fallback: () => fellBack = true,
      );
      expect(opened?['name'], 'Checking');
      expect(fellBack, isFalse);
    });

    test('unresolvable id (archived) → graceful fallback, no panel', () {
      Map<String, dynamic>? opened;
      var fellBack = false;
      routeAccountMoveJump(
        accounts: accounts,
        accountId: 'acc-archived',
        openPanel: (a) => opened = a,
        fallback: () => fellBack = true,
      );
      expect(opened, isNull);
      expect(fellBack, isTrue);
    });
  });
}
