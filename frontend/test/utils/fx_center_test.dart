import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/fx_center.dart';

void main() {
  group('linkedFxAmount', () {
    test('base -> target multiplies by the rate', () {
      expect(
        linkedFxAmount(input: '2', rate: 17.5, baseToTarget: true),
        '35.00',
      );
      expect(
        linkedFxAmount(input: '1.5', rate: 17.5, baseToTarget: true),
        '26.25',
      );
    });

    test('target -> base divides by the rate', () {
      expect(
        linkedFxAmount(input: '35', rate: 17.5, baseToTarget: false),
        '2.00',
      );
    });

    test('empty input clears the sibling field', () {
      expect(linkedFxAmount(input: '', rate: 17.5, baseToTarget: true), '');
      expect(linkedFxAmount(input: '   ', rate: 17.5, baseToTarget: true), '');
    });

    test('mid-typing / garbage input leaves the sibling untouched (null)', () {
      // "1." parses in Dart, but "." alone and "1.2.3" do not — the linked
      // field must not be wiped mid-keystroke.
      expect(linkedFxAmount(input: '.', rate: 17.5, baseToTarget: true), null);
      expect(
        linkedFxAmount(input: '1.2.3', rate: 17.5, baseToTarget: true),
        null,
      );
    });

    test('unusable rate returns null (never divides by zero)', () {
      expect(linkedFxAmount(input: '5', rate: 0, baseToTarget: false), null);
      expect(linkedFxAmount(input: '5', rate: -1, baseToTarget: true), null);
      expect(
        linkedFxAmount(input: '5', rate: double.nan, baseToTarget: true),
        null,
      );
    });

    test('respects the decimals parameter', () {
      expect(
        linkedFxAmount(
          input: '1',
          rate: 17.5678,
          baseToTarget: true,
          decimals: 4,
        ),
        '17.5678',
      );
    });
  });

  group('fxHistoryPoint', () {
    test('parses a well-formed backend point', () {
      final p = fxHistoryPoint({
        'rate': 17.58,
        'timestamp': '2026-07-20T12:00:00Z',
      });
      expect(p, isNotNull);
      expect(p!.close, 17.58);
      expect(p.date.toUtc().year, 2026);
    });

    test('rejects malformed rows instead of throwing', () {
      expect(fxHistoryPoint(null), null);
      expect(fxHistoryPoint('nope'), null);
      expect(fxHistoryPoint({'rate': 17.5}), null); // no timestamp
      expect(
        fxHistoryPoint({'rate': 0, 'timestamp': '2026-07-20T12:00:00Z'}),
        null,
      ); // zero-rate sentinel must not chart
      expect(fxHistoryPoint({'rate': 17.5, 'timestamp': 'garbage'}), null);
    });
  });

  group('fxPairOf', () {
    test('reads current field names', () {
      final pair = fxPairOf({'base': 'USD', 'target': 'MXN'});
      expect(pair.base, 'USD');
      expect(pair.target, 'MXN');
    });

    test('falls back to legacy *_currency names, then USD/MXN', () {
      final legacy = fxPairOf({
        'base_currency': 'EUR',
        'target_currency': 'MXN',
      });
      expect(legacy.base, 'EUR');
      expect(legacy.target, 'MXN');
      final empty = fxPairOf(const {});
      expect(empty.base, 'USD');
      expect(empty.target, 'MXN');
    });
  });
}
