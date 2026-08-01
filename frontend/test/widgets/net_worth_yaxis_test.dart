import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';

// The net-worth chart's Y-axis fit. Simple mode fits to the data so a short
// window isn't squashed; stacked mode grounds at 0; neither opens negative
// space under an all-positive series.

void main() {
  group('computeNetWorthYBounds', () {
    test(
      'simple mode: a short window fits to the data (floor NOT slammed to 0)',
      () {
        // 1-month-style: net worth ~2.30M moving within a ~20k band.
        final (minY, maxY) = computeNetWorthYBounds(
          dataMin: 2290000,
          dataMax: 2310000,
          baseValue: 2300000,
          stacked: false,
        );
        // The floor sits just below the data, NOT at 0 — that's the whole fix.
        expect(minY, greaterThan(2000000));
        expect(minY, lessThan(2290000));
        expect(maxY, greaterThan(2310000));
      },
    );

    test('simple mode: a wide all-positive range clamps the floor to 0', () {
      // 5-year-style: $1.4k early (single account) up to $2.3M now. The 15%
      // padding would push the floor negative; it must clamp to 0.
      final (minY, _) = computeNetWorthYBounds(
        dataMin: 1400,
        dataMax: 2300000,
        baseValue: 2300000,
        stacked: false,
      );
      expect(minY, 0);
    });

    test('simple mode: a genuinely negative series keeps a negative floor', () {
      final (minY, _) = computeNetWorthYBounds(
        dataMin: -5000,
        dataMax: 40000,
        baseValue: 20000,
        stacked: false,
      );
      expect(minY, lessThan(0));
    });

    test('stacked mode: floor is grounded at 0 even for a tight range', () {
      final (minY, _) = computeNetWorthYBounds(
        dataMin: 2290000,
        dataMax: 2310000,
        baseValue: 2300000,
        stacked: true,
      );
      expect(minY, 0);
    });

    test('flat data (zero span) still produces a sane padded band', () {
      final (minY, maxY) = computeNetWorthYBounds(
        dataMin: 50000,
        dataMax: 50000,
        baseValue: 50000,
        stacked: false,
      );
      expect(maxY, greaterThan(minY));
      expect(minY, lessThan(50000));
    });
  });
}
