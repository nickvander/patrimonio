import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/sync_progress.dart';

void main() {
  group('syncableInstitutionCount', () {
    test('counts only Plaid/crypto institutions, not manual/CSV/PDF', () {
      final data = [
        {'integration_type': 'plaid'},
        {'integration_type': 'coinbase'},
        {'integration_type': 'coinbase_oauth'},
        {'integration_type': 'manual'},
        {'integration_type': 'csv'},
        {'integration_type': 'pdf'},
      ];
      expect(syncableInstitutionCount(data), 3);
    });

    test('null / empty / malformed rows are tolerated', () {
      expect(syncableInstitutionCount(null), 0);
      expect(syncableInstitutionCount(const []), 0);
      expect(syncableInstitutionCount([1, 'x', null]), 0);
      expect(syncableInstitutionCount([{'integration_type': null}]), 0);
    });
  });

  group('syncedSinceCount', () {
    final start = DateTime.parse('2026-06-15T10:00:00Z');

    test('counts institutions whose last_synced_at advanced past start', () {
      final data = [
        {'last_synced_at': '2026-06-15T10:00:05Z'}, // after start → done
        {'last_synced_at': '2026-06-15T10:00:30Z'}, // after start → done
        {'last_synced_at': '2026-06-15T09:59:59Z'}, // before start → not yet
        {'last_synced_at': null}, // never synced → not yet
        {}, // missing field → not yet
      ];
      expect(syncedSinceCount(data, start), 2);
    });

    test('a leg exactly at start does not count (strictly after)', () {
      final data = [
        {'last_synced_at': '2026-06-15T10:00:00Z'},
      ];
      expect(syncedSinceCount(data, start), 0);
    });

    test('null / unparseable timestamps are tolerated', () {
      expect(syncedSinceCount(null, start), 0);
      expect(syncedSinceCount([{'last_synced_at': 'not-a-date'}], start), 0);
    });
  });
}
