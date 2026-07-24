import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/net_worth_delta.dart';

// The shared net-worth delta computation behind BOTH the dashboard hero badge
// and the net-worth card's trend chip. Pinned here: the tolerance-capped
// 30d → 7d anchor fallback and the honest window label — the hero chip used to
// claim "vs 30d ago" while silently comparing against the oldest snapshot
// (16 days old on the dev account), contradicting the card's honest "vs 7d
// ago" chip below it.

Map<String, dynamic> _point(String date, double netWorth) => {
      'date': date,
      'net_worth': netWorth,
    };

/// Daily history from [start] (inclusive) for [days] points, linearly
/// interpolated from [startValue] to [endValue].
List<Map<String, dynamic>> _dailyHistory(
  DateTime start,
  int days,
  double startValue,
  double endValue,
) =>
    List.generate(days, (i) {
      final d = start.add(Duration(days: i));
      final v = startValue + (endValue - startValue) * i / (days - 1);
      return _point(d.toIso8601String().substring(0, 10), v);
    });

void main() {
  group('computeNetWorthDelta — anchor fallback and honest label', () {
    test('16-day history (dev-account case) falls back to a 7d anchor '
        'and labels it 7d — never claims 30d', () {
      // Oldest snapshot is only 16 days before the latest: no point lands
      // within +/-5 days of the 30d target, so the 30d window MUST be
      // skipped, not silently satisfied by the oldest snapshot.
      final history = _dailyHistory(DateTime(2026, 7, 8), 17, 1000, 1160);
      final delta = computeNetWorthDelta(history);
      expect(delta, isNotNull);
      expect(delta!.windowLabel, '7d');
      // Anchor is exactly 7 days before the latest (2026-07-17, value 1090).
      expect(delta.amount, closeTo(1160 - 1090, 1e-9));
      expect(delta.percentage, closeTo((1160 - 1090) / 1090 * 100, 1e-9));
    });

    test('a month of history anchors at ~30d and labels it 30d', () {
      final history = _dailyHistory(DateTime(2026, 6, 24), 31, 1000, 1300);
      final delta = computeNetWorthDelta(history);
      expect(delta, isNotNull);
      expect(delta!.windowLabel, '30d');
      expect(delta.amount, closeTo(300, 1e-9));
      expect(delta.percentage, closeTo(30, 1e-9));
    });

    test('30d anchor tolerates a +/-5 day gap (nearest snapshot wins)', () {
      final history = [
        _point('2026-06-21', 1000), // 33 days back — within tolerance
        _point('2026-07-17', 1100),
        _point('2026-07-24', 1200),
      ];
      final delta = computeNetWorthDelta(history);
      expect(delta!.windowLabel, '30d');
      expect(delta.amount, closeTo(200, 1e-9));
    });

    test('null when no anchor lands within tolerance of either window', () {
      // Second point is 15 days before the latest: 15 days off the 30d
      // target and 8 days off the 7d target — both outside +/-5.
      final history = [
        _point('2026-07-09', 1000),
        _point('2026-07-24', 1200),
      ];
      expect(computeNetWorthDelta(history), isNull);
    });

    test('null when history has fewer than 2 parseable points', () {
      expect(computeNetWorthDelta(const []), isNull);
      expect(computeNetWorthDelta([_point('2026-07-24', 1000)]), isNull);
      expect(
        computeNetWorthDelta([
          _point('2026-07-24', 1000),
          {'date': 'not-a-date', 'net_worth': 900},
          {'date': '2026-07-17'}, // missing net_worth
          'not even a map',
        ]),
        isNull,
      );
    });

    test('negative baseline keeps the dollar delta, suppresses the %', () {
      final history = [
        _point('2026-06-24', -50000),
        _point('2026-07-24', -40000),
      ];
      final delta = computeNetWorthDelta(history);
      expect(delta, isNotNull);
      expect(delta!.windowLabel, '30d');
      expect(delta.amount, closeTo(10000, 1e-9));
      expect(delta.percentage, isNull);
    });

    test('onboarding-inflated 30d baseline (>3x) falls through to the 7d '
        'window with an honest 7d label', () {
      final history = [
        _point('2026-06-24', 100000), // accounts still being added
        _point('2026-07-17', 450000),
        _point('2026-07-24', 460000),
      ];
      final delta = computeNetWorthDelta(history);
      expect(delta, isNotNull);
      expect(delta!.windowLabel, '7d');
      expect(delta.amount, closeTo(10000, 1e-9));
      expect(delta.percentage, closeTo(10000 / 450000 * 100, 1e-9));
    });
  });

  group('computeMomYoyDeltas — calendar-anchored deltas', () {
    test('MoM present with a month of history, YoY absent', () {
      final history = [
        _point('2026-06-24', 1000),
        _point('2026-07-24', 1150),
      ];
      final deltas = computeMomYoyDeltas(history);
      expect(deltas.mom, isNotNull);
      expect(deltas.mom!.windowLabel, 'MoM');
      expect(deltas.mom!.amount, closeTo(150, 1e-9));
      expect(deltas.mom!.percentage, closeTo(15, 1e-9));
      expect(deltas.yoy, isNull);
    });

    test('YoY anchors at the same calendar date one year back', () {
      final history = [
        _point('2025-07-24', 1000),
        _point('2026-06-24', 1400),
        _point('2026-07-24', 1500),
      ];
      final deltas = computeMomYoyDeltas(history);
      expect(deltas.yoy, isNotNull);
      expect(deltas.yoy!.windowLabel, 'YoY');
      expect(deltas.yoy!.amount, closeTo(500, 1e-9));
      expect(deltas.yoy!.percentage, closeTo(50, 1e-9));
    });
  });
}
