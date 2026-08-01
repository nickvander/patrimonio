/// Degradation policy for the dashboard's silent refreshes.
///
/// WHY this exists: `_loadAllData` fans ~28 reads out through one
/// `Future.wait`, and a `Future.wait` rejects as soon as ANY future throws.
/// The post-mutation / realtime-push refreshes run with `silent: true`,
/// whose catch deliberately keeps the current screen rather than blanking
/// the dashboard — so a single endpoint hiccup used to discard the WHOLE
/// refresh, silently and with no retry. Observed failure: a statement
/// import landed server-side, `/dashboard/holdings` 503'd for a few
/// seconds, both post-import reloads died on it, and the new transactions
/// stayed invisible until the user hit "Sync now" (an explicit,
/// force-refreshing load).
///
/// The fix is two-part and lives here so it can be unit-tested without
/// `ApiService` (which imports `package:web` and can't load on the Dart
/// test VM):
///
///   * [keepPreviousOnError] — one read failing degrades to "keep what's
///     already on screen" instead of taking the other 27 down with it.
///   * [silentRetryDelay] — a bounded backoff so a degraded refresh
///     re-converges on its own once the hiccup passes.
library;

import 'dart:async';

/// Wrap one read of a silent refresh so its failure can't abort the whole
/// `Future.wait`.
///
/// Falls back to [previous] — the value currently on screen — and reports
/// the error through [onError] so the caller can schedule a retry. The
/// fallback applies ONLY when:
///
///   * [silent] is true. An explicit (user-initiated) load must still fail
///     loudly: that's the path that renders the error screen with a retry
///     button, and the user is waiting for an answer.
///   * [previous] is non-null. On the first load there's nothing to keep,
///     and quietly substituting an empty value would render a dashboard of
///     zeros — worse than the error screen.
///
/// [onError] fires only when the fallback is actually taken; a rethrown
/// error reaches the caller's own catch, which already handles it.
Future<T> keepPreviousOnError<T extends Object>(
  Future<T> read, {
  required T? previous,
  required bool silent,
  void Function(Object error)? onError,
}) {
  final fallback = previous;
  if (!silent || fallback == null) return read;
  return read.catchError((Object e) {
    onError?.call(e);
    return fallback;
  });
}

/// Backoff for re-running a silent refresh that came back degraded (at
/// least one read fell back to its previous value).
///
/// Returns the delay before attempt [attempt] (1-based), or null once the
/// attempts are exhausted — at which point we stop rather than poll a
/// broken backend forever. Recovery then rides on the next realtime push,
/// sub-screen return, or explicit refresh, all of which reload anyway.
///
/// The first retry is deliberately short: the common case is a seconds-long
/// blip (a cold external quote fetch, a dropped connection on a resuming
/// device), and the user is often still looking at the screen.
Duration? silentRetryDelay(int attempt) => switch (attempt) {
  1 => const Duration(seconds: 5),
  2 => const Duration(seconds: 15),
  3 => const Duration(seconds: 45),
  _ => null,
};
