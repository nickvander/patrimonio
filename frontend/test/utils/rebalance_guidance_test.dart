import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/widgets/rebalancing_card.dart';

// WS2r4: unit tests for the pure rebalancing helpers — the greedy
// surplus→deficit pairing (backlog R3: $500 floor, 3-line cap, rounding)
// and the defensive C4-A targets reader.

void main() {
  group('computeRebalanceMoves', () {
    test('one surplus, two deficits: greedy pairing largest-first '
        '(the GOOG-heavy owner shape)', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 78, 'bonds': 10, 'cash': 10, 'crypto': 2},
        targetPct: {'equity': 65, 'bonds': 20, 'cash': 10, 'crypto': 5},
        totalUsd: 1500000,
      );
      expect(g.allOnTarget, isFalse);
      expect(g.moves, hasLength(2));
      // Largest deficit (bonds, 10 pp = $150k) is filled first, consuming
      // the smaller side; the equity surplus's remaining 3 pp goes to crypto.
      expect(g.moves[0].from, 'equity');
      expect(g.moves[0].to, 'bonds');
      expect(g.moves[0].amountUsd, 150000);
      expect(g.moves[1].from, 'equity');
      expect(g.moves[1].to, 'crypto');
      expect(g.moves[1].amountUsd, 45000);
      expect(g.truncated, isFalse);
    });

    test(r'moves under the $500 floor are suppressed and flag truncation', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 60, 'bonds': 20, 'other': 20},
        targetPct: {'equity': 55, 'bonds': 22.6, 'other': 22.4},
        totalUsd: 20000,
      );
      // Raw pairing: equity→bonds $520 (kept), equity→other $480
      // (suppressed by the floor). The elided move surfaces as "…and
      // smaller adjustments".
      expect(g.moves, hasLength(1));
      expect(g.moves.single.from, 'equity');
      expect(g.moves.single.to, 'bonds');
      expect(g.moves.single.amountUsd, 520);
      expect(g.truncated, isTrue);
      expect(g.allOnTarget, isFalse);
    });

    test('caps at 3 lines, largest first, canonical-order tie-break', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 60},
        targetPct: {
          'equity': 40,
          'bonds': 5,
          'cash': 4,
          'crypto': 4,
          'real_estate': 4,
          'commodities': 3,
        },
        totalUsd: 100000,
      );
      expect(g.moves, hasLength(3));
      expect(g.truncated, isTrue);
      expect(g.moves[0].to, 'bonds');
      expect(g.moves[0].amountUsd, 5000);
      // 4 pp three-way tie resolves in canonical class order.
      expect(g.moves[1].to, 'cash');
      expect(g.moves[2].to, 'crypto');
      expect(g.moves.every((m) => m.from == 'equity'), isTrue);
    });

    test('amounts are rounded to whole dollars', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 60, 'bonds': 0},
        targetPct: {'equity': 50, 'bonds': 10},
        totalUsd: 10001,
      );
      // 10 pp of $10,001 = $1,000.10 → rounds to $1,000.
      expect(g.moves.single.amountUsd, 1000);
    });

    test('all drifts within ±2 pp → on-target, no moves', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 66, 'bonds': 19.5, 'cash': 10, 'other': 4.5},
        targetPct: {'equity': 65, 'bonds': 20, 'cash': 10, 'other': 5},
        totalUsd: 1500000,
      );
      expect(g.allOnTarget, isTrue);
      expect(g.moves, isEmpty);
      expect(g.truncated, isFalse);
    });

    test('out-of-band drift on a tiny portfolio: every move under the '
        'floor → silence, but NOT reported as on-target', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 63, 'cash': 37},
        targetPct: {'equity': 60, 'cash': 40},
        totalUsd: 10000,
      );
      expect(g.moves, isEmpty);
      expect(g.allOnTarget, isFalse);
      expect(g.truncated, isFalse);
    });

    test('unclassified is excluded from pairing (untargetable)', () {
      final g = computeRebalanceMoves(
        actualPct: {'equity': 50, 'unclassified': 50},
        targetPct: {'equity': 60},
        totalUsd: 100000,
      );
      // The equity deficit has no surplus counterpart — unclassified must
      // never be suggested as a source.
      expect(g.moves, isEmpty);
      expect(g.allOnTarget, isFalse);
    });
  });

  group('parseAllocationTargets (C4-A reader)', () {
    test('null → unset (never-written and cleared share one path)', () {
      final p = parseAllocationTargets(null);
      expect(p.unset, isTrue);
      expect(p.malformed, isFalse);
    });

    test('valid shape → ok with the percentage map', () {
      final p = parseAllocationTargets({
        'v': 1,
        'targets': {'equity': 65, 'bonds': 20, 'cash': 10, 'other': 5},
      });
      expect(p.unset, isFalse);
      expect(p.malformed, isFalse);
      expect(p.targets, {
        'equity': 65.0,
        'bonds': 20.0,
        'cash': 10.0,
        'other': 5.0,
      });
    });

    test('unknown keys are ignored, not fatal', () {
      final p = parseAllocationTargets({
        'v': 1,
        'targets': {'equity': 60, 'bonds': 40, 'unicorns': 10},
      });
      expect(p.malformed, isFalse);
      expect(p.targets, {'equity': 60.0, 'bonds': 40.0});
    });

    test('bad sum → malformed with salvaged values for the editor prefill', () {
      final p = parseAllocationTargets({
        'v': 1,
        'targets': {'equity': 50},
      });
      expect(p.malformed, isTrue);
      expect(p.targets, {'equity': 50.0});
    });

    test('non-numeric value / wrong envelope → malformed', () {
      expect(
        parseAllocationTargets({
          'v': 1,
          'targets': {'equity': 'lots'},
        }).malformed,
        isTrue,
      );
      expect(parseAllocationTargets('garbage').malformed, isTrue);
      expect(parseAllocationTargets({'v': 1}).malformed, isTrue);
    });

    test('out-of-range value → malformed', () {
      final p = parseAllocationTargets({
        'v': 1,
        'targets': {'equity': 120, 'bonds': -20},
      });
      expect(p.malformed, isTrue);
    });
  });
}
