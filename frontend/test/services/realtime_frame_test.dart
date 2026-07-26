import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/realtime_service.dart';

/// The wire contract with `backend/src/services/realtime.rs`. Guards the
/// heartbeat added for socket liveness: it must NOT fall through to
/// `unknown`, which the dashboard treats as "reload everything" — that
/// would turn a 30-second keep-alive into a 30-second refetch storm.
void main() {
  RealtimeEventType? typeOf(String raw) => parseRealtimeFrame(raw)?.type;

  group('parseRealtimeFrame', () {
    test('heartbeat is its own type, not unknown', () {
      expect(typeOf('{"event":"heartbeat"}'), RealtimeEventType.heartbeat);
      expect(typeOf('{"event":"heartbeat"}'), isNot(RealtimeEventType.unknown));
    });

    test('maps the data-change events the dashboard reloads on', () {
      expect(typeOf('{"event":"transactions_changed"}'),
          RealtimeEventType.transactionsChanged);
      expect(typeOf('{"event":"accounts_changed"}'),
          RealtimeEventType.accountsChanged);
      expect(typeOf('{"event":"fx_rates_updated"}'),
          RealtimeEventType.fxRatesUpdated);
      expect(typeOf('{"event":"resync"}'), RealtimeEventType.resync);
    });

    test('carries the institution name on sync_complete', () {
      final e = parseRealtimeFrame(
          '{"event":"sync_complete","institution":"Chase"}');
      expect(e!.type, RealtimeEventType.syncComplete);
      expect(e.institution, 'Chase');
    });

    test('an unrecognized event still reloads (fail-safe, not fail-quiet)', () {
      expect(typeOf('{"event":"something_new"}'), RealtimeEventType.unknown);
    });

    test('a malformed frame is ignored rather than thrown', () {
      expect(parseRealtimeFrame('not json'), isNull);
      expect(parseRealtimeFrame('[]'), isNull);
    });
  });
}
