import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/resilient_reload.dart';

/// Regression cover for the "import landed but Home didn't update" bug:
/// one endpoint hiccup used to reject the dashboard's whole `Future.wait`,
/// the silent catch kept the pre-import screen, and nothing retried — the
/// new transactions only appeared after the user forced a sync.
void main() {
  group('keepPreviousOnError', () {
    test('passes the fresh value through when the read succeeds', () async {
      var errors = 0;
      final v = await keepPreviousOnError(
        Future.value(<String, dynamic>{'net_worth': 2}),
        previous: <String, dynamic>{'net_worth': 1},
        silent: true,
        onError: (_) => errors++,
      );
      expect(v['net_worth'], 2);
      expect(errors, 0, reason: 'no failure, no retry signal');
    });

    test('keeps the on-screen value when a silent read fails', () async {
      final errors = <Object>[];
      final v = await keepPreviousOnError(
        Future<List<dynamic>>.error(Exception('Failed to load holdings')),
        previous: <dynamic>['on screen'],
        silent: true,
        onError: errors.add,
      );
      expect(v, <dynamic>['on screen']);
      expect(errors, hasLength(1), reason: 'caller must be able to retry');
    });

    test(
      'one failing read does not abort the others in a Future.wait',
      () async {
        // The exact shape of _loadAllData's fan-out: the failing read is the
        // reason the whole refresh used to be discarded.
        var degraded = false;
        final results = await Future.wait([
          keepPreviousOnError(
            Future.value(<dynamic>['fresh txs']),
            previous: <dynamic>['old txs'],
            silent: true,
          ),
          keepPreviousOnError(
            Future<List<dynamic>>.error(Exception('503')),
            previous: <dynamic>['old holdings'],
            silent: true,
            onError: (_) => degraded = true,
          ),
        ]);
        expect(results[0], <dynamic>[
          'fresh txs',
        ], reason: 'the healthy read still updates the screen');
        expect(results[1], <dynamic>['old holdings']);
        expect(degraded, isTrue);
      },
    );

    test('rethrows on an explicit (non-silent) load', () async {
      // The user is waiting on this one — it must reach the error screen.
      await expectLater(
        keepPreviousOnError(
          Future<List<dynamic>>.error(Exception('boom')),
          previous: <dynamic>['on screen'],
          silent: false,
        ),
        throwsException,
      );
    });

    test('rethrows when there is no previous value to keep', () async {
      // First load: substituting an empty value would paint a dashboard of
      // zeros, which is worse than the error screen.
      await expectLater(
        keepPreviousOnError(
          Future<List<dynamic>>.error(Exception('boom')),
          previous: null,
          silent: true,
        ),
        throwsException,
      );
    });
  });

  group('silentRetryDelay', () {
    test('backs off over a bounded number of attempts', () {
      expect(silentRetryDelay(1), const Duration(seconds: 5));
      expect(silentRetryDelay(2), const Duration(seconds: 15));
      expect(silentRetryDelay(3), const Duration(seconds: 45));
    });

    test('gives up rather than polling a broken backend forever', () {
      expect(silentRetryDelay(4), isNull);
      expect(silentRetryDelay(99), isNull);
    });

    test('first retry is short enough to catch a seconds-long blip', () {
      expect(silentRetryDelay(1)!.inSeconds, lessThanOrEqualTo(10));
    });
  });
}
