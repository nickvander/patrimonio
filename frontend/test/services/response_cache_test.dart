import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/response_cache.dart';

/// These tests run on the plain Dart VM — ResponseCache has no
/// package:web / Flutter imports, so we test the caching logic directly
/// rather than subclassing ApiService (which would pull package:web into
/// the test VM and break it).
void main() {
  group('ResponseCache hit / miss', () {
    test('miss fetches and caches; subsequent read is a hit (no re-fetch)',
        () async {
      final cache = ResponseCache(ttl: const Duration(seconds: 30));
      var calls = 0;
      Future<int> fetch() async {
        calls++;
        return 42;
      }

      expect(cache.isFresh('k'), isFalse);
      expect(await cache.getOrFetch('k', fetch), 42);
      expect(calls, 1);
      expect(cache.isFresh('k'), isTrue);

      // Second read inside TTL must not call fetch again.
      expect(await cache.getOrFetch('k', fetch), 42);
      expect(calls, 1);
    });

    test('set / peek stores a value directly', () {
      final cache = ResponseCache();
      expect(cache.peek('k'), isNull);
      cache.set('k', 'v');
      expect(cache.peek('k'), 'v');
      expect(cache.isFresh('k'), isTrue);
    });
  });

  group('TTL expiry + stale-while-revalidate', () {
    test('past TTL the entry is no longer fresh', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final cache = ResponseCache(
        ttl: const Duration(seconds: 25),
        clock: () => now,
      );
      cache.set('k', 1);
      expect(cache.isFresh('k'), isTrue);

      now = now.add(const Duration(seconds: 24));
      expect(cache.isFresh('k'), isTrue);

      now = now.add(const Duration(seconds: 2)); // total 26s > 25s
      expect(cache.isFresh('k'), isFalse);
    });

    test('stale read returns old value immediately AND revalidates', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final cache = ResponseCache(
        ttl: const Duration(seconds: 25),
        clock: () => now,
      );
      var calls = 0;
      var nextValue = 1;
      Future<int> fetch() async {
        calls++;
        return nextValue;
      }

      // Prime the cache.
      expect(await cache.getOrFetch('k', fetch), 1);
      expect(calls, 1);

      // Advance past TTL and change what the server would return.
      now = now.add(const Duration(seconds: 30));
      nextValue = 2;

      // Stale read: returns the OLD value synchronously-ish...
      expect(await cache.getOrFetch('k', fetch), 1);
      // ...and triggered a background revalidation.
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);

      // The revalidation refreshed the entry. Reset clock freshness by
      // re-stamping: the background fetch stored value 2 at `now`, so it's
      // fresh again and the next read serves the new value with no fetch.
      expect(await cache.getOrFetch('k', fetch), 2);
      expect(calls, 2);
    });
  });

  group('invalidation', () {
    test('invalidate drops a single key', () {
      final cache = ResponseCache();
      cache.set('a', 1);
      cache.set('b', 2);
      cache.invalidate('a');
      expect(cache.peek('a'), isNull);
      expect(cache.peek('b'), 2);
    });

    test('invalidatePrefix drops a family', () {
      final cache = ResponseCache();
      cache.set('dash:loans/summary', 1);
      cache.set('dash:loans/reminders', 2);
      cache.set('dash:overview', 3);
      cache.invalidatePrefix('dash:loans/');
      expect(cache.peek('dash:loans/summary'), isNull);
      expect(cache.peek('dash:loans/reminders'), isNull);
      expect(cache.peek('dash:overview'), 3);
    });

    test('clear drops everything', () {
      final cache = ResponseCache();
      cache.set('a', 1);
      cache.set('b', 2);
      cache.clear();
      expect(cache.peek('a'), isNull);
      expect(cache.peek('b'), isNull);
    });

    test('a fetch in flight when clear() runs does NOT repopulate the cache',
        () async {
      // This is the core finance-safety guard: a read that started before
      // a mutation must not write its now-stale result back after the
      // mutation invalidated the cache.
      final cache = ResponseCache();
      final completer = Completer<int>();
      final read = cache.getOrFetch('k', () => completer.future);

      // Mutation happens while the fetch is outstanding.
      cache.clear();

      // Now the in-flight fetch resolves with pre-mutation data.
      completer.complete(99);
      expect(await read, 99); // caller still gets its value
      // ...but it must NOT have been cached (it predates the clear()).
      expect(cache.peek('k'), isNull);
      expect(cache.isFresh('k'), isFalse);
    });
  });

  group('in-flight de-dupe', () {
    test('concurrent identical reads share ONE fetch', () async {
      final cache = ResponseCache();
      var calls = 0;
      final completer = Completer<int>();
      Future<int> fetch() {
        calls++;
        return completer.future;
      }

      final f1 = cache.getOrFetch('k', fetch);
      final f2 = cache.getOrFetch('k', fetch);
      final f3 = cache.getOrFetch('k', fetch);

      completer.complete(7);
      expect(await Future.wait([f1, f2, f3]), [7, 7, 7]);
      expect(calls, 1); // de-duped to a single network call
    });

    test('a fresh fetch after the in-flight one settles is a new call',
        () async {
      final cache = ResponseCache(ttl: const Duration(seconds: 30));
      var calls = 0;
      Future<int> fetch() async {
        calls++;
        return calls;
      }

      expect(await cache.getOrFetch('k', fetch), 1);
      cache.invalidate('k');
      expect(await cache.getOrFetch('k', fetch), 2);
      expect(calls, 2);
    });
  });

  group('forceRefresh', () {
    test('bypasses a fresh cached value and re-fetches', () async {
      final cache = ResponseCache(ttl: const Duration(seconds: 30));
      var calls = 0;
      Future<int> fetch() async {
        calls++;
        return calls;
      }

      expect(await cache.getOrFetch('k', fetch), 1);
      expect(calls, 1);

      // Fresh entry exists, but forceRefresh ignores it.
      expect(await cache.getOrFetch('k', fetch, forceRefresh: true), 2);
      expect(calls, 2);
      // And the fresh value was cached.
      expect(await cache.getOrFetch('k', fetch), 2);
      expect(calls, 2);
    });

    test('forceRefresh joins an already in-flight fetch', () async {
      // The outstanding fetch is already the freshest data we can get;
      // forceRefresh should reuse it rather than issue a duplicate call.
      final cache = ResponseCache();
      var calls = 0;
      final completer = Completer<int>();
      Future<int> fetch() {
        calls++;
        return completer.future;
      }

      final normal = cache.getOrFetch('k', fetch);
      final forced = cache.getOrFetch('k', fetch, forceRefresh: true);
      completer.complete(5);
      expect(await normal, 5);
      expect(await forced, 5);
      expect(calls, 1);
    });

    test('a forceRefresh AFTER clear() does not join a pre-clear in-flight '
        'fetch — it starts a fresh one', () async {
      // Finance-safety: a realtime-triggered reload that lands right after a
      // mutation must not de-dupe onto the pre-mutation network call and
      // surface its stale value. clear() forgets the in-flight marker so the
      // forced read fetches fresh.
      final cache = ResponseCache();
      var calls = 0;
      final first = Completer<int>(); // pre-mutation (stale) value
      final second = Completer<int>(); // post-mutation (fresh) value
      Future<int> fetch() {
        calls++;
        return calls == 1 ? first.future : second.future;
      }

      final stale = cache.getOrFetch('k', fetch); // starts call #1
      cache.clear(); // mutation invalidates everything
      final fresh = cache.getOrFetch('k', fetch, forceRefresh: true); // call #2

      second.complete(2); // fresh data resolves
      first.complete(1); // old call resolves later, harmlessly

      expect(await fresh, 2); // forced read got the FRESH value, not 1
      expect(await stale, 1); // the original caller still gets its own value
      expect(calls, 2); // two distinct network calls — not de-duped
    });
  });

  test('fetch error is not cached and propagates to the caller', () async {
    final cache = ResponseCache();
    var calls = 0;
    Future<int> fetch() async {
      calls++;
      throw StateError('boom');
    }

    await expectLater(cache.getOrFetch('k', fetch), throwsStateError);
    expect(cache.peek('k'), isNull);
    // The in-flight marker was cleared, so a retry actually re-fetches.
    await expectLater(cache.getOrFetch('k', fetch), throwsStateError);
    expect(calls, 2);
  });
}
