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
    final spots = dayOffsetSpots(dedupeDailyCloses([
      pt('2026-01-01', 10.0),
      pt('2026-01-02', 11.0),
      pt('2026-03-03', 12.0), // 60-day hole
    ]));
    expect(spots, const [
      FlSpot(0, 10.0),
      FlSpot(1, 11.0),
      FlSpot(61, 12.0),
    ]);
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
}
