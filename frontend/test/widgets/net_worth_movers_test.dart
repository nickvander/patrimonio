import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';

// The since-baseline net-worth movers helper: pick the snapshot nearest the
// baseline date (+/-5 days), diff each institution latest-vs-baseline, sort by
// |Δ|, cap at top 3. Signs follow the direction of change; hidden (empty) when
// there aren't two comparable snapshots or no institution data.

Map<String, dynamic> _point(
  String date,
  double netWorth,
  Map<String, double> byInst,
) => {'date': date, 'net_worth': netWorth, 'by_institution': byInst};

void main() {
  group('topInstitutionMovers', () {
    test('hidden (empty) when fewer than 2 snapshots', () {
      final history = [
        _point('2026-06-08', 1000, {'Chase': 1000}),
      ];
      expect(topInstitutionMovers(history, DateTime(2026, 5, 8)), isEmpty);
    });

    test('empty when no snapshot lands within the +/-5 day tolerance', () {
      final history = [
        // Baseline candidate is 20 days off the target → out of tolerance.
        _point('2026-05-18', 1000, {'Chase': 1000}),
        _point('2026-06-08', 1200, {'Chase': 1200}),
      ];
      // Target one month before latest = 2026-05-08; nearest is 10 days away.
      expect(topInstitutionMovers(history, DateTime(2026, 5, 8)), isEmpty);
    });

    test('baseline selection snaps to the nearest point within tolerance', () {
      final history = [
        _point('2026-05-06', 500, {'Chase': 500}), // 2 days off target
        _point('2026-05-10', 800, {'Chase': 800}), // 2 days off target too
        _point('2026-06-08', 1000, {'Chase': 1000}),
      ];
      // Target 2026-05-08: both candidates are equidistant (2 days); the first
      // one scanned wins (May 6, value 500) → delta 1000-500 = 500.
      final movers = topInstitutionMovers(history, DateTime(2026, 5, 8));
      expect(movers, hasLength(1));
      expect(movers.first.name, 'Chase');
      expect(movers.first.delta, 500);
    });

    test('sorts by absolute change and caps at top 3', () {
      final history = [
        _point('2026-05-08', 0, {
          'A': 100,
          'B': 100,
          'C': 100,
          'D': 100,
          'E': 100,
        }),
        _point('2026-06-08', 0, {
          'A': 110, // +10
          'B': 60, // -40
          'C': 200, // +100
          'D': 105, // +5
          'E': 50, // -50
        }),
      ];
      final movers = topInstitutionMovers(history, DateTime(2026, 5, 8));
      expect(movers, hasLength(3)); // top-3 cap
      // Sorted by |Δ|: C(+100), E(-50), B(-40).
      expect(movers.map((m) => m.name).toList(), ['C', 'E', 'B']);
      expect(movers[0].delta, 100);
      expect(movers[1].delta, -50);
      expect(movers[2].delta, -40);
    });

    test('sign follows the direction of change (down = negative delta)', () {
      final history = [
        _point('2026-05-08', 1000, {'Fidelity': 1000}),
        _point('2026-06-08', 700, {'Fidelity': 700}),
      ];
      final movers = topInstitutionMovers(history, DateTime(2026, 5, 8));
      expect(movers, hasLength(1));
      expect(movers.first.delta, -300);
      expect(movers.first.delta.isNegative, isTrue);
    });

    test('new / dropped institution is diffed against an implicit zero', () {
      final history = [
        _point('2026-05-08', 1000, {'Chase': 1000}),
        // Chase gone, Vanguard newly appears.
        _point('2026-06-08', 1500, {'Vanguard': 1500}),
      ];
      final movers = topInstitutionMovers(history, DateTime(2026, 5, 8));
      final byName = {for (final m in movers) m.name: m.delta};
      expect(byName['Vanguard'], 1500); // 1500 - 0
      expect(byName['Chase'], -1000); // 0 - 1000
    });

    test('empty when neither endpoint carries by_institution data', () {
      final history = [
        _point('2026-05-08', 1000, {}),
        _point('2026-06-08', 1200, {}),
      ];
      expect(topInstitutionMovers(history, DateTime(2026, 5, 8)), isEmpty);
    });
  });
}
