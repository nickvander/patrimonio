import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/sync_progress.dart';

void main() {
  group('syncableInstitutionCount', () {
    test('counts Plaid/crypto institutions, not manual/CSV/PDF', () {
      final data = [
        {'integration_type': 'plaid'},
        {'integration_type': 'coinbase'},
        {'integration_type': 'coinbase_oauth'},
        {'integration_type': 'bitso'},
        {'integration_type': 'manual'},
        {'integration_type': 'csv'},
        {'integration_type': 'pdf'},
      ];
      expect(syncableInstitutionCount(data), 4);
    });

    test('null / empty / malformed rows are tolerated', () {
      expect(syncableInstitutionCount(null), 0);
      expect(syncableInstitutionCount(const []), 0);
      expect(syncableInstitutionCount([1, 'x', null]), 0);
      expect(syncableInstitutionCount([{'integration_type': null}]), 0);
    });
  });

  group('syncingCount', () {
    test('counts syncable institutions still in the syncing state', () {
      final data = [
        {'integration_type': 'plaid', 'sync_status': 'syncing'}, // in progress
        {'integration_type': 'coinbase', 'sync_status': 'syncing'}, // in progress
        {'integration_type': 'plaid', 'sync_status': 'synced'}, // done
        {'integration_type': 'plaid', 'sync_status': 'error'}, // done (errored)
      ];
      expect(syncingCount(data), 2);
    });

    test('an errored institution counts as done, not stuck', () {
      // The whole point of the status-based count: a failing/timed-out
      // institution leaves 'syncing', so it no longer wedges progress.
      final data = [
        {'integration_type': 'plaid', 'sync_status': 'synced'},
        {'integration_type': 'plaid', 'sync_status': 'error'},
      ];
      expect(syncingCount(data), 0);
    });

    test('non-syncable rows in a transient syncing state are ignored', () {
      // The engine briefly stamps manual rows 'syncing' before flipping them
      // to 'manual'; those must not count toward the syncable progress.
      final data = [
        {'integration_type': 'manual', 'sync_status': 'syncing'},
        {'integration_type': 'csv', 'sync_status': 'syncing'},
      ];
      expect(syncingCount(data), 0);
    });

    test('null / empty / malformed rows are tolerated', () {
      expect(syncingCount(null), 0);
      expect(syncingCount(const []), 0);
      expect(syncingCount([1, 'x', null]), 0);
      expect(syncingCount([{'integration_type': 'plaid'}]), 0); // no status
    });
  });
}
