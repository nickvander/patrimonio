import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/drill_down_claim.dart';

/// The balance-claim reconciliation threshold: the line shows only when
/// |claim − shownSum| exceeds max($1, 5% of |claim|). Both sides of the
/// boundary, both claim signs, and the small-claim $1 floor.
void main() {
  group(r'balanceClaimHasGap — 5% regime (|claim| ≥ $20)', () {
    test('gap just over 5% of the claim → line shows', () {
      expect(balanceClaimHasGap(claimAmount: 1000.0, shownSum: 949.0), isTrue);
    });

    test('gap just under 5% of the claim → no line', () {
      expect(balanceClaimHasGap(claimAmount: 1000.0, shownSum: 951.0), isFalse);
    });

    test('gap exactly AT the threshold → no line (strictly "exceeds")', () {
      expect(balanceClaimHasGap(claimAmount: 1000.0, shownSum: 950.0), isFalse);
    });

    test('negative claim uses |claim| for the 5% bound', () {
      expect(
        balanceClaimHasGap(claimAmount: -1000.0, shownSum: -949.0),
        isTrue,
      );
      expect(
        balanceClaimHasGap(claimAmount: -1000.0, shownSum: -951.0),
        isFalse,
      );
    });
  });

  group(r'balanceClaimHasGap — $1 floor (small claims)', () {
    test(r'5% of a $10 claim is $0.50, but the floor is $1: a $0.90 gap '
        'stays quiet', () {
      expect(balanceClaimHasGap(claimAmount: 10.0, shownSum: 9.1), isFalse);
    });

    test(r'a $1.10 gap on the same claim shows the line', () {
      expect(balanceClaimHasGap(claimAmount: 10.0, shownSum: 8.9), isTrue);
    });
  });

  test('a fully-explained move (gap 0) never shows the line', () {
    expect(balanceClaimHasGap(claimAmount: 500.0, shownSum: 500.0), isFalse);
  });

  test('an entirely-unexplained move (no visible rows, sum 0) shows it', () {
    expect(balanceClaimHasGap(claimAmount: 500.0, shownSum: 0.0), isTrue);
  });
}
