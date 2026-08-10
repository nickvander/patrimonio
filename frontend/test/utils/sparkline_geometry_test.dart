import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/sparkline_geometry.dart';

// Geometry for the home-screen widget's sparkline — the only part of that
// bitmap that can be verified off an emulator, so everything decidable lives
// here rather than in the painter.

void main() {
  group('sparklinePoints', () {
    test('maps oldest→newest left→right, larger values higher', () {
      final pts = sparklinePoints(
        [10, 20, 30],
        width: 100,
        height: 50,
        inset: 0,
      );
      expect(pts, hasLength(3));
      expect(pts.first.x, 0);
      expect(pts.last.x, 100);
      // Canvas y grows downward: the max value sits at the TOP (y = 0).
      expect(pts.last.y, 0);
      expect(pts.first.y, 50);
      expect(pts[1].y, 25);
    });

    test('inset keeps the stroke inside the bitmap', () {
      final pts = sparklinePoints([1, 2], width: 100, height: 40, inset: 4);
      // Without this, a 4px stroke at the extreme clips half its width off.
      expect(pts.first.x, 4);
      expect(pts.last.x, 96);
      expect(pts.first.y, 36); // min value → bottom, inset off the edge
      expect(pts.last.y, 4); // max value → top, inset off the edge
    });

    test('a flat month is a midline, not a divide-by-zero', () {
      final pts = sparklinePoints(
        [500.0, 500.0, 500.0],
        width: 100,
        height: 40,
      );
      expect(pts, hasLength(3));
      for (final p in pts) {
        expect(p.y, 20);
      }
    });

    test('fewer than two points claims nothing', () {
      // A dot is not a trend; the provider hides the image instead.
      expect(sparklinePoints([1], width: 100, height: 40), isEmpty);
      expect(sparklinePoints([], width: 100, height: 40), isEmpty);
    });
  });

  group('thinSparkline', () {
    test('short series pass through untouched', () {
      final values = [1.0, 2.0, 3.0];
      expect(thinSparkline(values, maxPoints: 60), same(values));
    });

    test('long series thin to the cap, keeping both endpoints', () {
      final year = [for (var i = 0; i < 365; i++) i.toDouble()];
      final thinned = thinSparkline(year, maxPoints: 60);
      expect(thinned, hasLength(60));
      // The endpoints are the two points a trend cannot lie about: where it
      // started and where it is now.
      expect(thinned.first, 0.0);
      expect(thinned.last, 364.0);
    });

    test('sampling is monotone over a monotone series', () {
      final year = [for (var i = 0; i < 365; i++) i.toDouble()];
      final thinned = thinSparkline(year, maxPoints: 60);
      for (var i = 1; i < thinned.length; i++) {
        expect(thinned[i], greaterThan(thinned[i - 1]));
      }
    });
  });
}
