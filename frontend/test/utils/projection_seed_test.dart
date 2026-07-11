import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/projection_seed.dart';

// F4: the Monte Carlo seed must be a pure function of the request parameters
// — identical inputs ⇒ identical seed ⇒ identical uncertainty fan.

void main() {
  const params = 'start_balance=500000.0&monthly_contribution=1000.0'
      '&annual_return_rate=0.07&years=30';

  test('same inputs produce the same seed', () {
    expect(projectionSeed(params), projectionSeed(params));
  });

  test('seed is stable across releases (pinned value)', () {
    // Pinning an exact value guards against the hash algorithm silently
    // changing, which would re-roll every user's fan on upgrade.
    expect(projectionSeed(''), 0x811C9DC5); // FNV-1a offset basis.
    expect(projectionSeed('a'), 0x2B24D044); // FNV-1a('a\x00'), 16-bit units.
  });

  test('different inputs produce different seeds', () {
    final base = projectionSeed(params);
    expect(projectionSeed('${params}1'), isNot(base));
    expect(
      projectionSeed(params.replaceFirst('1000.0', '1000.5')),
      isNot(base),
    );
  });

  test('seed is non-negative and within u64 (32-bit, JS-safe)', () {
    for (final input in ['', 'a', params, 'ünïcode ✓ %20']) {
      final seed = projectionSeed(input);
      expect(seed, greaterThanOrEqualTo(0));
      expect(seed, lessThanOrEqualTo(0xFFFFFFFF));
    }
  });
}
