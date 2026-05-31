import 'dart:async';

/// A tiny, self-contained, stale-while-revalidate cache for idempotent
/// GET reads.
///
/// WHY this exists: `ApiService` had zero client-side caching, so every
/// dashboard reload (returning from a sub-screen, each realtime websocket
/// event, every post-mutation refresh) fired the full ~15-endpoint
/// `Future.wait` again — re-pulling holdings, net-worth history,
/// allocation, trends, etc. That meant redundant network traffic and a
/// perceptible flash/sluggishness.
///
/// This component is deliberately free of `package:web` / Flutter
/// imports so it can be unit-tested on the plain Dart VM (subclassing
/// `ApiService` in tests pulls `package:web` and breaks the test VM).
///
/// Correctness model (finance app — never serve wrong numbers):
///   * Entries carry a conservative TTL. Within the TTL a read is a
///     pure cache hit (no network).
///   * Past the TTL the value is *stale*: [getOrFetch] returns it
///     immediately AND kicks off a background revalidation so the next
///     read is fresh (stale-while-revalidate). Callers that must never
///     see stale data pass `forceRefresh: true`.
///   * Concurrent identical reads share ONE in-flight network call
///     (in-flight de-dupe).
///   * Any mutation invalidates aggressively via [invalidate] /
///     [invalidatePrefix] / [clear]; the simplest safe wiring clears the
///     whole dashboard cache on ANY mutation.
class ResponseCache {
  ResponseCache({
    Duration ttl = const Duration(seconds: 25),
    DateTime Function() clock = _wallClock,
  })  : _ttl = ttl,
        _now = clock;

  final Duration _ttl;
  final DateTime Function() _now;

  static DateTime _wallClock() => DateTime.now();

  final Map<String, _CacheEntry> _entries = <String, _CacheEntry>{};

  /// In-flight fetches keyed identically to [_entries]. A second caller
  /// for the same key while a fetch is outstanding awaits the same
  /// future instead of issuing a duplicate network call.
  final Map<String, Future<dynamic>> _inFlight = <String, Future<dynamic>>{};

  /// Whether [key] has a fresh (non-expired) value cached right now.
  bool isFresh(String key) {
    final e = _entries[key];
    if (e == null) return false;
    return !_isExpired(e);
  }

  bool _isExpired(_CacheEntry e) => _now().difference(e.storedAt) >= _ttl;

  /// Read the cached value for [key] if present, regardless of freshness.
  /// Returns null when absent. Primarily for tests / introspection;
  /// production reads should go through [getOrFetch].
  Object? peek(String key) => _entries[key]?.value;

  /// Store [value] under [key] with the current timestamp.
  void set(String key, Object? value) {
    _entries[key] = _CacheEntry(value, _now());
  }

  /// Drop a single key.
  void invalidate(String key) {
    _entries.remove(key);
  }

  /// Drop every key beginning with [prefix]. Useful for scoping an
  /// invalidation to a family of endpoints (e.g. everything under
  /// `loans/`).
  void invalidatePrefix(String prefix) {
    _entries.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// Drop everything. The default post-mutation strategy.
  ///
  /// In-flight fetches are intentionally NOT cancelled (we can't cancel a
  /// `Future`), but their results are dropped rather than cached: see the
  /// `_inFlight`-vs-current-token guard in [getOrFetch]. This prevents a
  /// network call that started *before* a mutation from writing
  /// now-stale data back into the cache after the mutation cleared it.
  ///
  /// We also forget the `_inFlight` markers so a `forceRefresh` that lands
  /// AFTER the clear (e.g. a realtime-triggered reload right after a write)
  /// starts a genuinely fresh fetch instead of de-duping onto a pre-mutation
  /// call and receiving its now-stale value for one paint. The orphaned
  /// pre-clear fetch still settles harmlessly: its generation-guarded `set`
  /// is skipped and its `whenComplete` won't evict the newer marker (the
  /// `identical` check fails).
  void clear() {
    _entries.clear();
    _inFlight.clear();
    _generation++;
  }

  /// Monotonic counter bumped on [clear]. A fetch captures the
  /// generation at start; if [clear] ran while it was outstanding, the
  /// fetch refuses to populate the cache (its data predates the
  /// invalidation and may be stale).
  int _generation = 0;

  /// The core read path.
  ///
  /// * Fresh hit  -> returns the cached value, no network.
  /// * Stale hit  -> returns the cached value immediately AND triggers a
  ///                 background revalidation (stale-while-revalidate).
  /// * Miss       -> awaits [fetch], caches, returns it.
  /// * [forceRefresh] -> ignores any cached value, awaits a fresh fetch,
  ///                 caches it. Used by realtime-triggered and explicit
  ///                 user-initiated refreshes so they never serve stale
  ///                 finance data.
  ///
  /// Concurrent identical calls share one in-flight [fetch].
  Future<T> getOrFetch<T>(
    String key,
    Future<T> Function() fetch, {
    bool forceRefresh = false,
  }) {
    final entry = _entries[key];

    if (!forceRefresh && entry != null) {
      if (!_isExpired(entry)) {
        // Fresh: pure cache hit.
        return Future<T>.value(entry.value as T);
      }
      // Stale: serve immediately, revalidate in the background. The
      // background fetch shares the in-flight de-dupe so a concurrent
      // explicit fetch won't double up.
      _revalidate<T>(key, fetch);
      return Future<T>.value(entry.value as T);
    }

    // Miss, or forceRefresh: must await the network. De-dupe concurrent
    // identical fetches. A forceRefresh still joins an existing in-flight
    // fetch — that outstanding call is already the freshest data we can
    // get, so reusing it is both correct and cheaper.
    return _fetchDeduped<T>(key, fetch);
  }

  Future<T> _fetchDeduped<T>(String key, Future<T> Function() fetch) {
    final existing = _inFlight[key];
    if (existing != null) {
      return existing.then((v) => v as T);
    }
    final startGeneration = _generation;
    // Build the whole chain in one expression so the future we store and
    // return is the SAME object the cleanup hangs off — deriving a second
    // future from it (e.g. an orphan `whenComplete`) would leak an
    // unhandled error when `fetch` throws and no one awaits that branch.
    late final Future<T> future;
    future = fetch().then((value) {
      // Only populate if no clear() happened while we were in flight —
      // otherwise we'd resurrect data the mutation just invalidated.
      if (_generation == startGeneration) {
        set(key, value);
      }
      return value;
    }).whenComplete(() {
      // Drop the in-flight marker once settled (success or error) so the
      // next read re-fetches rather than awaiting a dead future. Guarded so
      // a fetch that was superseded by a newer one for the same key doesn't
      // evict the newer marker.
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = future;
    return future;
  }

  /// Fire-and-forget background revalidation for a stale entry. Errors
  /// are swallowed: the caller already has a (stale) value to show, and
  /// a transient network failure shouldn't surface as an unhandled
  /// exception. The next read retries.
  void _revalidate<T>(String key, Future<T> Function() fetch) {
    if (_inFlight.containsKey(key)) return; // de-dupe with any live fetch
    // Swallow errors at the Future level so a transient failure on a
    // background refresh never surfaces as an unhandled exception. We
    // ignore() rather than catchError(() => T) because T is non-nullable
    // and we have no value to substitute — the existing stale entry stays.
    unawaited(_fetchDeduped<T>(key, fetch).then<void>(
      (_) {},
      onError: (_) {},
    ));
  }
}

class _CacheEntry {
  _CacheEntry(this.value, this.storedAt);
  final Object? value;
  final DateTime storedAt;
}
