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
) => List.generate(days, (i) {
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
      final history = [_point('2026-07-09', 1000), _point('2026-07-24', 1200)];
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
      final history = [_point('2026-06-24', 1000), _point('2026-07-24', 1150)];
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

  // Whether the net-worth card offers its FX-free replot. The control used to
  // be offered whenever the series loaded, so in a quiet FX month pressing it
  // redrew a line that traced the old one — which is what made it read as
  // doing nothing. The gate is "would this look different", measured against
  // the span the chart's y-axis is fitted to.
  group('fxViewIsInformative', () {
    // The real shape of the complaint: $1.6M net worth, a $46k month, $639 of
    // it FX. Half a percent of the plotted span — invisible.
    test('a quiet FX month does not earn the control', () {
      expect(
        fxViewIsInformative(
          fxUsd: 639.32,
          constantFxUsd: const [1500000, 1550000, 1610000],
        ),
        isFalse,
      );
    });

    test('a peso swing that reshapes a flat month does', () {
      expect(
        fxViewIsInformative(
          fxUsd: -6000,
          constantFxUsd: const [1600000, 1602000, 1605000],
        ),
        isTrue,
      );
    });

    test(
      'the threshold is a share of the plotted span, not a dollar floor',
      () {
        // Same $1k of FX: decisive against a $5k span, invisible against $100k.
        expect(
          fxViewIsInformative(fxUsd: 1000, constantFxUsd: const [0, 5000]),
          isTrue,
        );
        expect(
          fxViewIsInformative(fxUsd: 1000, constantFxUsd: const [0, 100000]),
          isFalse,
        );
      },
    );

    test('exactly at the threshold is offered', () {
      expect(
        fxViewIsInformative(
          fxUsd: 1000 * kFxVisibleShareOfSpan,
          constantFxUsd: const [0, 1000],
        ),
        isTrue,
      );
    });

    test('sign does not matter — a peso rally hides as much as a crash', () {
      for (final fx in const [7500.0, -7500.0]) {
        expect(
          fxViewIsInformative(fxUsd: fx, constantFxUsd: const [0, 50000]),
          isTrue,
          reason: 'fx=$fx',
        );
      }
    });

    test('zero FX never earns a control', () {
      expect(
        fxViewIsInformative(fxUsd: 0, constantFxUsd: const [0, 1000]),
        isFalse,
      );
    });

    test('a flat series with any FX movement is the visible extreme', () {
      // The live line is level and the constant-FX one cannot be.
      expect(
        fxViewIsInformative(fxUsd: 50, constantFxUsd: const [1000, 1000]),
        isTrue,
      );
    });

    test('fewer than two points is not a line to compare against', () {
      expect(
        fxViewIsInformative(fxUsd: 5000, constantFxUsd: const [1000]),
        isFalse,
      );
      expect(
        fxViewIsInformative(fxUsd: 5000, constantFxUsd: const []),
        isFalse,
      );
    });

    test('the span is min-to-max, not first-to-last', () {
      // A round trip: ends where it started, but the chart is fitted to the
      // dip it took. FX under a tenth of THAT is still invisible.
      expect(
        fxViewIsInformative(
          fxUsd: 500,
          constantFxUsd: const [100000, 90000, 100000],
        ),
        isFalse,
      );
    });
  });
}
