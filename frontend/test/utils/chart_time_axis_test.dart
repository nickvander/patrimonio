import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/chart_time_axis.dart';

// Mirrors the `day-offset x-axis math (I3)` group in
// instrument_detail_sheet_test.dart — the helpers were copied verbatim into
// utils/chart_time_axis.dart so performance_card can share them, so the same
// contract must hold here.
void main() {
  ({DateTime date, double close}) pt(String iso, double close) =>
      (date: DateTime.parse(iso), close: close);

  test('dedupeDailyCloses keeps the LAST close per day and sorts by day', () {
    final out = dedupeDailyCloses([
      pt('2026-01-02', 11.0),
      pt('2026-01-01 10:00:00', 10.0),
      pt('2026-01-01 18:00:00', 10.5),
    ]);
    expect(out.length, 2);
    expect(out[0].date, DateTime.utc(2026, 1, 1));
    expect(out[0].close, 10.5);
    expect(out[1].date, DateTime.utc(2026, 1, 2));
    expect(out[1].close, 11.0);
  });

  test('dayOffsetSpots keeps real gaps: x is days since the first sample', () {
    final spots = dayOffsetSpots(
      dedupeDailyCloses([
        pt('2026-01-01', 10.0),
        pt('2026-01-02', 11.0),
        pt('2026-03-03', 12.0), // 60-day hole
      ]),
    );
    expect(spots, const [FlSpot(0, 10.0), FlSpot(1, 11.0), FlSpot(61, 12.0)]);
  });

  test('dayOffsetSpots on empty input is empty', () {
    expect(dayOffsetSpots(const []), isEmpty);
  });

  test('dayOffsetTickInterval is span/3, floored at one day', () {
    expect(dayOffsetTickInterval(366), 122.0);
    expect(dayOffsetTickInterval(90), 30.0);
    expect(dayOffsetTickInterval(2), 1.0); // 2-point series stays valid
    expect(dayOffsetTickInterval(0), 1.0);
  });

  group('nonRepeatingDateFormat', () {
    test('a dense sub-year axis escalates past the repeating month format', () {
      // The reported case: ~140 days of history, most ticks inside one month.
      // "MMM y" would print "Jul 2026" over and over, so day precision wins.
      final ticks = _days('2026-03-15', [0, 110, 118, 126, 134, 140]);
      final labels = _labels(ticks, spanDays: 140);
      expect(
        labels.where((l) => l == 'Jul 2026'),
        isEmpty,
        reason: 'the seven-identical-labels bug: $labels',
      );
      _expectNoAdjacentRepeat(labels);
    });

    test('a genuinely multi-month axis keeps the coarse month format', () {
      final ticks = _days('2024-01-15', [0, 200, 400, 600, 800]);
      expect(_labels(ticks, spanDays: 800).first, 'Jan 2024');
    });

    test('short spans still prefer day precision over month precision', () {
      // Unchanged behaviour: a 30-day window reads better as "Mar 15" than
      // "Mar 2026" even though the month format would not have repeated.
      final ticks = _days('2026-03-01', [0, 10, 20, 30]);
      expect(_labels(ticks, spanDays: 30), [
        'Mar 1',
        'Mar 11',
        'Mar 21',
        'Mar 31',
      ]);
    });

    test(
      'same calendar day in different years falls through to the year form',
      () {
        // A short reported span starts the ladder at "MMM d", which collides
        // here — Jul 4 two years running — so it escalates one rung further.
        final ticks = [DateTime(2025, 7, 4), DateTime(2026, 7, 4)];
        final labels = _labels(ticks, spanDays: 40);
        expect(labels, ['Jul 4, 2025', 'Jul 4, 2026']);
        _expectNoAdjacentRepeat(labels);
      },
    );

    test('degenerate inputs do not throw', () {
      expect(_labels(const [], spanDays: 0), isEmpty);
      expect(_labels(_days('2026-03-01', [0]), spanDays: 0), hasLength(1));
      // No span information at all → month format is the starting preference.
      expect(_labels(_days('2026-03-01', [0, 400])).first, 'Mar 2026');
    });
  });
}

// ---------------------------------------------------------------------------
// nonRepeatingDateFormat — the axis must not print the same label twice in a
// row. Reported from the phone: a 1Y net-worth chart whose history spans ~140
// days rendered "Jul 2026" seven times, because the format was chosen from the
// axis's total SPAN while collisions are decided by the gap between TICKS.
// ---------------------------------------------------------------------------

List<DateTime> _days(String first, List<int> offsets) {
  final start = DateTime.parse(first);
  return [for (final o in offsets) start.add(Duration(days: o))];
}

List<String> _labels(List<DateTime> ticks, {int? spanDays}) {
  final f = nonRepeatingDateFormat(ticks, spanDays: spanDays);
  return [for (final d in ticks) f.format(d)];
}

void _expectNoAdjacentRepeat(List<String> labels) {
  for (var i = 1; i < labels.length; i++) {
    expect(
      labels[i],
      isNot(labels[i - 1]),
      reason: 'adjacent ticks must differ: $labels',
    );
  }
}
