import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/month_window.dart';

void main() {
  group('monthWindow', () {
    test('mid-year month spans first to last day', () {
      final w = monthWindow('2026-07');
      expect(w, isNotNull);
      expect(w!.start, DateTime(2026, 7, 1));
      expect(w.end, DateTime(2026, 7, 31));
    });

    test('30-day and February months get the right last day', () {
      expect(monthWindow('2026-06')!.end, DateTime(2026, 6, 30));
      expect(monthWindow('2026-02')!.end, DateTime(2026, 2, 28));
      expect(monthWindow('2028-02')!.end, DateTime(2028, 2, 29)); // leap
    });

    test('December does not roll into January', () {
      final w = monthWindow('2025-12')!;
      expect(w.start, DateTime(2025, 12, 1));
      // DateTime(2025, 13, 0) must resolve to Dec 31, not a January date.
      expect(w.end, DateTime(2025, 12, 31));
    });

    test('malformed input returns null instead of crashing', () {
      expect(monthWindow(''), isNull);
      expect(monthWindow('2026'), isNull);
      expect(monthWindow('garbage'), isNull);
      expect(monthWindow('abcd-ef'), isNull);
      expect(monthWindow('2026-00'), isNull);
      expect(monthWindow('2026-13'), isNull);
      // A full date is not a month key — reject rather than silently
      // resolving to that date's month.
      expect(monthWindow('2026-07-15'), isNull);
    });
  });
}
