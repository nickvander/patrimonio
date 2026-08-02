import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/tx_page.dart';

/// TxPage — the typed result of one paged transaction fetch: decoded rows
/// plus the whole-table total from the X-Total-Count response header.
void main() {
  group('TxPage.totalFromHeaders', () {
    test('parses a present header ("2502" → 2502)', () {
      expect(TxPage.totalFromHeaders({'x-total-count': '2502'}), 2502);
    });

    test('absent header → null (older backend / empty result)', () {
      expect(TxPage.totalFromHeaders(const {}), isNull);
      expect(
        TxPage.totalFromHeaders({'content-type': 'application/json'}),
        isNull,
      );
    });

    test('garbage value → null, treated like an older backend', () {
      expect(TxPage.totalFromHeaders({'x-total-count': 'abc'}), isNull);
      expect(TxPage.totalFromHeaders({'x-total-count': ''}), isNull);
      expect(TxPage.totalFromHeaders({'x-total-count': '12.5'}), isNull);
    });

    test('only the lowercase key is honored — package:http lowercases '
        'header names, so that is the form callers ever see', () {
      expect(TxPage.totalFromHeaders({'X-Total-Count': '10'}), isNull);
      expect(TxPage.totalFromHeaders({'x-total-count': '10'}), 10);
    });
  });

  group('hasMore derivation (loaded < total)', () {
    // The consumers (dashboard + account panel) derive
    // hasMore = loaded < totalCount when the header is present.
    bool hasMore({required int loaded, required int total}) => loaded < total;

    test('mid-history: more pages remain', () {
      expect(hasMore(loaded: 50, total: 2502), isTrue);
      expect(hasMore(loaded: 2501, total: 2502), isTrue);
    });

    test('exact multiple of the page size: the old "full page ⇒ maybe '
        'more" heuristic got this wrong and cost one extra empty '
        'round-trip; the exact form does not', () {
      // 500 rows loaded, 500 total — a full final page.
      expect(hasMore(loaded: 500, total: 500), isFalse);
    });

    test('fully loaded: no more', () {
      expect(hasMore(loaded: 2502, total: 2502), isFalse);
    });
  });
}
