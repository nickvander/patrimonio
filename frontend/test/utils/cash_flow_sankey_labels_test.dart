import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/cash_flow_sankey.dart';

/// Pure-geometry contract for Sankey label placement.
///
/// The bug these pin: a node rect is VALUE-sized, so a $26 slice of a $620
/// period is about one pixel tall. The original painter centred a two-line
/// label block on that rect with no collision avoidance, and four of six value
/// labels came out overprinted into mush. The invariant here is absolute —
/// placed blocks are pairwise disjoint, always.

SankeyLabelCandidate _c(
  String id,
  double centerY, {
  double height = 26,
  double priority = 1,
  double left = 0,
  double width = 110,
}) => SankeyLabelCandidate(
  nodeId: id,
  left: left,
  width: width,
  height: height,
  preferredCenterY: centerY,
  priority: priority,
);

void _expectDisjoint(List<Rect> rects) {
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      final overlap = rects[i].intersect(rects[j]);
      expect(
        overlap.width > 0 && overlap.height > 0,
        isFalse,
        reason: 'blocks $i ${rects[i]} and $j ${rects[j]} overlap',
      );
    }
  }
}

void main() {
  group('placeSankeyLabels', () {
    test('pushes overprinting blocks apart and keeps them in order', () {
      // The shipped failure: four small nodes 20/16/13px apart with 26px
      // blocks. Every adjacent pair overlapped.
      final placed = placeSankeyLabels(
        [
          _c('a', 63.5, priority: 520),
          _c('b', 139.5, priority: 67.85),
          _c('c', 161.3, priority: 26),
          _c('d', 176.5, priority: 4.69),
          _c('e', 189.5, priority: 1.46),
        ],
        minY: 0,
        maxY: 268,
      );
      expect(placed, hasLength(5));
      _expectDisjoint([for (final p in placed) p.rect]);
      // Top-to-bottom order still tracks the nodes' own order — a Sankey whose
      // labels are reshuffled is worse than one with none.
      expect(
        [for (final p in placed) p.candidate.nodeId],
        ['a', 'b', 'c', 'd', 'e'],
      );
      for (final p in placed) {
        expect(p.rect.top, greaterThanOrEqualTo(0));
        expect(p.rect.bottom, lessThanOrEqualTo(268));
      }
    });

    test('leaves already-clear blocks exactly where they wanted to be', () {
      final placed = placeSankeyLabels(
        [_c('a', 40), _c('b', 120), _c('c', 200)],
        minY: 0,
        maxY: 268,
      );
      expect(placed.map((p) => p.rect.center.dy), [40, 120, 200]);
    });

    test('pulls a bottom-crowded column back inside its bounds', () {
      final placed = placeSankeyLabels(
        [_c('a', 190), _c('b', 196), _c('c', 199)],
        minY: 0,
        maxY: 200,
      );
      expect(placed, hasLength(3));
      _expectDisjoint([for (final p in placed) p.rect]);
      expect(placed.last.rect.bottom, lessThanOrEqualTo(200));
      expect(placed.first.rect.top, greaterThanOrEqualTo(0));
    });

    test('drops the SMALLEST nodes when the column cannot fit them all', () {
      // 6 blocks of 26 need 145px with gaps; only 90px is available.
      final placed = placeSankeyLabels(
        [
          _c('big', 10, priority: 900),
          _c('mid', 30, priority: 90),
          _c('small', 50, priority: 9),
          _c('tiny', 60, priority: 0.9),
          _c('dust', 70, priority: 0.09),
          _c('speck', 80, priority: 0.009),
        ],
        minY: 0,
        maxY: 90,
      );
      // Deliberate, visible degradation: the three biggest keep their labels,
      // the rest are omitted (their amount is still tappable) rather than
      // painted on top of a neighbour.
      expect(placed.map((p) => p.candidate.nodeId).toSet(), {
        'big',
        'mid',
        'small',
      });
      _expectDisjoint([for (final p in placed) p.rect]);
    });

    test('no room at all → no labels, never an overprinted one', () {
      expect(placeSankeyLabels([_c('a', 5)], minY: 0, maxY: 10), isEmpty);
      expect(placeSankeyLabels([], minY: 0, maxY: 100), isEmpty);
    });

    test('a pathological comb of tiny nodes never overlaps', () {
      final candidates = <SankeyLabelCandidate>[
        for (var i = 0; i < 24; i++)
          _c('n$i', 100 + i * 1.4, priority: 100.0 - i),
      ];
      final placed = placeSankeyLabels(candidates, minY: 0, maxY: 420);
      _expectDisjoint([for (final p in placed) p.rect]);
      // 420px fits 14 blocks of 26 + 3px gaps; the rest are dropped, not stacked.
      expect(placed.length, lessThan(24));
      expect(placed, isNotEmpty);
    });
  });

  group('middleEllipsize', () {
    // 6px per character — enough to reproduce the real trap deterministically.
    double measure(String s) => s.length * 6.0;

    test('leaves a fitting string untouched', () {
      expect(
        middleEllipsize('Rent & utilities', 200, measure),
        'Rent & utilities',
      );
    });

    test('keeps two sources sharing a long prefix distinguishable', () {
      // Tail-ellipsis rendered BOTH of these as "Dividend received - …",
      // which is the whole reason the diagram bothers to name sources.
      const a = 'Dividend received - AAPL';
      const b = 'Dividend received - O (monthly)';
      final ea = middleEllipsize(a, 110, measure);
      final eb = middleEllipsize(b, 110, measure);
      expect(ea, isNot(eb));
      expect(measure(ea), lessThanOrEqualTo(110));
      expect(measure(eb), lessThanOrEqualTo(110));
      // The discriminating token lives at the END of a bank label, so the tail
      // is what must survive.
      expect(ea, endsWith('AAPL'));
      expect(eb, endsWith('nthly)'));
      expect(ea, contains('…'));
    });

    test('degrades to the ellipsis alone rather than overflowing', () {
      expect(middleEllipsize('anything', 3, measure), '…');
      expect(middleEllipsize('anything', 0, measure), '');
    });
  });

  group('sankeyLabelValueText', () {
    double measure(String s) => s.length * 6.0;

    test('prefers EXACT money so the diagram matches the card above it', () {
      // compactMoney printed "$67.9" next to MonthlyCashFlowCard's "$67.85".
      expect(sankeyLabelValueText(67.85, 'USD', 110, measure), r'$67.85');
      expect(sankeyLabelValueText(520, 'USD', 110, measure), r'$520.00');
    });

    test('falls back to compact only when exact cannot fit the gutter', () {
      // "MXN 1,234,567.89" is 16 chars → 96px, over a 68px phone gutter.
      final compact = sankeyLabelValueText(1234567.89, 'MXN', 68, measure);
      expect(compact, isNot(contains('1,234,567')));
      expect(measure(compact), lessThanOrEqualTo(68));
    });
  });
}
