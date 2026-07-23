import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/import_staleness.dart';

Map<String, dynamic> _acc({
  String institution = 'Banamex',
  String integration = 'manual',
  String? lastDataAt,
}) =>
    {
      'institution_name': institution,
      'integration_type': integration,
      'last_data_at': ?lastDataAt,
    };

String _daysAgo(int days, {DateTime? now}) =>
    (now ?? DateTime.now().toUtc())
        .subtract(Duration(days: days))
        .toIso8601String();

void main() {
  final now = DateTime.utc(2026, 7, 23, 12);

  group('staleThresholdFrom', () {
    test('absent / non-numeric values default to 30', () {
      expect(staleThresholdFrom(null), kDefaultImportStaleDays);
      expect(staleThresholdFrom('soon'), kDefaultImportStaleDays);
      expect(staleThresholdFrom({}), kDefaultImportStaleDays);
    });

    test('hostile numbers are clamped, mirroring the backend', () {
      expect(staleThresholdFrom(0), 1);
      expect(staleThresholdFrom(-9), 1);
      expect(staleThresholdFrom(1000000), 365);
    });

    test('in-range numbers pass through (ints and JSON doubles)', () {
      expect(staleThresholdFrom(45), 45);
      expect(staleThresholdFrom(45.0), 45);
    });
  });

  group('accountDataAgeDays', () {
    test('parses last_data_at and returns whole days', () {
      final acc = _acc(lastDataAt: _daysAgo(40, now: now));
      expect(accountDataAgeDays(acc, now: now), 40);
    });

    test('null for synced accounts / missing or garbage timestamps', () {
      expect(accountDataAgeDays(_acc(integration: 'plaid')), isNull);
      expect(accountDataAgeDays(_acc()), isNull);
      expect(
          accountDataAgeDays(_acc(lastDataAt: 'not-a-date'), now: now), isNull);
      expect(accountDataAgeDays('not-a-map'), isNull);
    });

    test('a slightly future server timestamp reads 0, never negative', () {
      final acc =
          _acc(lastDataAt: now.add(const Duration(hours: 2)).toIso8601String());
      expect(accountDataAgeDays(acc, now: now), 0);
    });
  });

  group('staleImportInstitutions', () {
    test('flags a manual institution past the threshold, most-stale first',
        () {
      final stale = staleImportInstitutions([
        _acc(institution: 'Banamex', lastDataAt: _daysAgo(40, now: now)),
        _acc(institution: 'CetesDirecto', lastDataAt: _daysAgo(90, now: now)),
        _acc(institution: 'Nu México', lastDataAt: _daysAgo(3, now: now)),
      ], thresholdDays: 30, now: now);
      expect(stale.map((s) => s.name), ['CetesDirecto', 'Banamex']);
      expect(stale.first.daysStale, 90);
    });

    test('the freshest account clears the whole institution', () {
      // Mirrors the backend's MAX(last_data_at): one recent import means
      // the institution is current even if a sibling account is dormant.
      final stale = staleImportInstitutions([
        _acc(institution: 'Banamex', lastDataAt: _daysAgo(200, now: now)),
        _acc(institution: 'Banamex', lastDataAt: _daysAgo(5, now: now)),
      ], thresholdDays: 30, now: now);
      expect(stale, isEmpty);
    });

    test('synced accounts and accounts without last_data_at never contribute',
        () {
      final stale = staleImportInstitutions([
        _acc(
            institution: 'Chase',
            integration: 'plaid',
            lastDataAt: _daysAgo(400, now: now)),
        _acc(institution: 'Banamex'), // manual but no timestamp
      ], thresholdDays: 30, now: now);
      expect(stale, isEmpty);
    });

    test('threshold boundary: exactly N days old is stale, N-1 is not', () {
      final at30 = staleImportInstitutions(
          [_acc(lastDataAt: _daysAgo(30, now: now))],
          thresholdDays: 30, now: now);
      final at29 = staleImportInstitutions(
          [_acc(lastDataAt: _daysAgo(29, now: now))],
          thresholdDays: 30, now: now);
      expect(at30, hasLength(1));
      expect(at29, isEmpty);
    });
  });
}
