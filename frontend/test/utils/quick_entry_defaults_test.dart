import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/quick_entry_defaults.dart';

// Quick entry is only worth having if its defaults are right, so the
// derivation is pinned here against real transaction-payload shapes:
// manual-only, ordered by INSERT time (not posted date), scoped to
// accounts that still exist, and recency-ordered categories that never
// offer the "Uncategorized" sentinel as a one-tap chip.

const _accounts = [
  {'id': 'acct-cash', 'name': 'Efectivo', 'currency': 'MXN'},
  {'id': 'acct-bank', 'name': 'Banorte', 'currency': 'MXN'},
];

Map<String, dynamic> _tx({
  required String accountId,
  String source = 'manual',
  String date = '2026-08-01',
  String? createdAt,
  String? category,
  String? userCategory,
  String? detailed,
}) => {
  'account_id': accountId,
  'source': source,
  'date': date,
  'created_at': ?createdAt,
  'category': ?category,
  'user_category': ?userCategory,
  'category_detailed': ?detailed,
};

void main() {
  group('lastManualAccountId', () {
    test('picks the account of the most recently ADDED manual row', () {
      final txs = [
        _tx(accountId: 'acct-bank', createdAt: '2026-08-01T10:00:00Z'),
        _tx(accountId: 'acct-cash', createdAt: '2026-08-02T09:00:00Z'),
        _tx(accountId: 'acct-bank', createdAt: '2026-07-30T09:00:00Z'),
      ];
      expect(lastManualAccountId(txs, _accounts), 'acct-cash');
    });

    test('created_at wins over the posted date', () {
      // A cash row typed TODAY for last Friday is still the latest entry:
      // sorting on the posted date would hand back the wrong account.
      final txs = [
        _tx(
          accountId: 'acct-bank',
          date: '2026-08-03',
          createdAt: '2026-08-01T08:00:00Z',
        ),
        _tx(
          accountId: 'acct-cash',
          date: '2026-07-25',
          createdAt: '2026-08-02T08:00:00Z',
        ),
      ];
      expect(lastManualAccountId(txs, _accounts), 'acct-cash');
    });

    test('falls back to the posted date when created_at is absent', () {
      final txs = [
        _tx(accountId: 'acct-bank', date: '2026-07-01'),
        _tx(accountId: 'acct-cash', date: '2026-07-20'),
      ];
      expect(lastManualAccountId(txs, _accounts), 'acct-cash');
    });

    test('ignores non-manual rows entirely', () {
      final txs = [
        _tx(
          accountId: 'acct-bank',
          source: 'plaid',
          createdAt: '2026-08-09T09:00:00Z',
        ),
        _tx(
          accountId: 'acct-bank',
          source: 'csv',
          createdAt: '2026-08-08T09:00:00Z',
        ),
        _tx(accountId: 'acct-cash', createdAt: '2026-07-01T09:00:00Z'),
      ];
      expect(lastManualAccountId(txs, _accounts), 'acct-cash');
    });

    test('skips a manual row whose account is no longer in the list', () {
      final txs = [
        _tx(accountId: 'acct-closed', createdAt: '2026-08-05T09:00:00Z'),
        _tx(accountId: 'acct-bank', createdAt: '2026-08-04T09:00:00Z'),
      ];
      expect(lastManualAccountId(txs, _accounts), 'acct-bank');
    });

    test('null when there is no usable manual history', () {
      expect(lastManualAccountId(const [], _accounts), isNull);
      expect(
        lastManualAccountId([
          _tx(accountId: 'acct-cash', source: 'plaid'),
        ], _accounts),
        isNull,
      );
    });

    test('tolerates junk rows without throwing', () {
      final txs = <dynamic>[
        'not a map',
        null,
        {'source': 'manual'},
        _tx(accountId: 'acct-cash', createdAt: '2026-08-05T09:00:00Z'),
      ];
      expect(lastManualAccountId(txs, _accounts), 'acct-cash');
    });
  });

  group('recentManualCategories', () {
    test('orders by recency, not alphabetically', () {
      final txs = [
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Zapatos',
          createdAt: '2026-08-03T09:00:00Z',
        ),
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Abarrotes',
          createdAt: '2026-08-02T09:00:00Z',
        ),
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Gasolina',
          createdAt: '2026-08-01T09:00:00Z',
        ),
      ];
      expect(recentManualCategories(txs), ['Zapatos', 'Abarrotes', 'Gasolina']);
    });

    test('dedupes case-insensitively, keeping the newest spelling', () {
      final txs = [
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Tacos',
          createdAt: '2026-08-03T09:00:00Z',
        ),
        _tx(
          accountId: 'acct-cash',
          userCategory: 'tacos',
          createdAt: '2026-08-02T09:00:00Z',
        ),
      ];
      expect(recentManualCategories(txs), ['Tacos']);
    });

    test('never offers the Uncategorized sentinel as a chip', () {
      // prettyCategory renders a category-less row as "Uncategorized";
      // tapping that would persist a placeholder as a real category.
      final txs = [
        _tx(accountId: 'acct-cash', createdAt: '2026-08-03T09:00:00Z'),
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Tacos',
          createdAt: '2026-08-02T09:00:00Z',
        ),
      ];
      expect(recentManualCategories(txs), ['Tacos']);
    });

    test('ignores non-manual rows', () {
      final txs = [
        _tx(
          accountId: 'acct-cash',
          source: 'plaid',
          userCategory: 'Plaid thing',
          createdAt: '2026-08-09T09:00:00Z',
        ),
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Tacos',
          createdAt: '2026-08-02T09:00:00Z',
        ),
      ];
      expect(recentManualCategories(txs), ['Tacos']);
    });

    test('a user override beats the auto category on the same row', () {
      final txs = [
        _tx(
          accountId: 'acct-cash',
          category: 'GENERAL_MERCHANDISE',
          userCategory: 'Tacos',
          createdAt: '2026-08-02T09:00:00Z',
        ),
      ];
      expect(recentManualCategories(txs), ['Tacos']);
    });

    test('honours the limit', () {
      final txs = [
        for (var i = 0; i < 12; i++)
          _tx(
            accountId: 'acct-cash',
            userCategory: 'Cat$i',
            createdAt:
                '2026-08-${(12 - i).toString().padLeft(2, '0')}'
                'T09:00:00Z',
          ),
      ];
      expect(recentManualCategories(txs).length, 6);
      expect(recentManualCategories(txs, limit: 3), ['Cat0', 'Cat1', 'Cat2']);
    });

    test('pads from the fallback without displacing recent entries', () {
      final txs = [
        _tx(
          accountId: 'acct-cash',
          userCategory: 'Tacos',
          createdAt: '2026-08-02T09:00:00Z',
        ),
      ];
      expect(
        recentManualCategories(
          txs,
          fallback: const ['Abarrotes', 'tacos', 'Gasolina'],
          limit: 3,
        ),
        // 'tacos' is a case-insensitive duplicate of the recent 'Tacos'
        // and is dropped rather than offered twice.
        ['Tacos', 'Abarrotes', 'Gasolina'],
      );
    });

    test('a first-run user gets the fallback alone', () {
      expect(
        recentManualCategories(
          const [],
          fallback: const ['Abarrotes', 'Gasolina'],
        ),
        ['Abarrotes', 'Gasolina'],
      );
    });
  });
}
