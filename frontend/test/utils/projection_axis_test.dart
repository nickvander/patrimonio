import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/projection_axis.dart';

// F7: adaptive x-axis label step for the projection chart (was a fixed 5,
// which overlapped labels on phones with long horizons).

void main() {
  test('phone plot, 50-year horizon: step 25 (3 well-spaced labels)', () {
    // 290px / 56 ≈ 5 labels max; steps 5/10 need 11/6, 15/20 drop the final
    // year, so 25 wins: Yr 0 / 25 / 50 with no risk of collision.
    expect(
      projectionYearAxisInterval(plotWidth: 290, projectionYears: 50),
      25.0,
    );
  });

  test('wide plot, 30-year horizon: step 5 (7 labels, fits ~1/62px)', () {
    expect(
      projectionYearAxisInterval(plotWidth: 740, projectionYears: 30),
      5.0,
    );
  });

  test('phone plot, 30-year horizon: step 10 keeps the last-year label', () {
    // 290px / 56 ≈ 5 labels; step 5 needs 7, step 10 divides 30 → 4 labels.
    expect(
      projectionYearAxisInterval(plotWidth: 290, projectionYears: 30),
      10.0,
    );
  });

  test('prefers a step that divides the horizon (keeps first + last)', () {
    final step =
        projectionYearAxisInterval(plotWidth: 400, projectionYears: 45)
            .toInt();
    expect(45 % step, 0);
  });

  test('degenerate width still returns a usable positive step', () {
    final step =
        projectionYearAxisInterval(plotWidth: 0, projectionYears: 50);
    expect(step, greaterThan(0));
  });

  test('short horizon on a wide plot uses the finest clean step', () {
    expect(
      projectionYearAxisInterval(plotWidth: 900, projectionYears: 5),
      5.0,
    );
  });
}
