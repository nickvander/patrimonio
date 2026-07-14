import 'package:flutter/material.dart' show Axis, kToolbarHeight;
import 'package:flutter/rendering.dart' show ScrollDirection;

/// Pure decision logic for the compact scroll-away app bar
/// (enter-always + snap semantics).
///
/// Fed from bubbling [UserScrollNotification]s on the dashboard. Returns the
/// bar's new visibility, or `null` when the notification should not change it:
///
/// * Horizontal scrollables (filter-chip rows, period selectors) never touch
///   the bar — only [Axis.vertical] notifications are considered.
/// * `pixels <= 0` FORCES the bar visible regardless of direction. This
///   protects pull-to-refresh: the RefreshIndicator overscroll fires at scroll
///   extent 0 and the bar must never fight the pull.
/// * [ScrollDirection.reverse] (user scrolling content up) hides the bar, but
///   only once the list is past [kToolbarHeight] — tiny nudges at the top
///   don't collapse it.
/// * [ScrollDirection.forward] (any downward flick) restores it immediately.
/// * [ScrollDirection.idle] leaves it alone.
bool? barVisibleAfter({
  required ScrollDirection direction,
  required Axis axis,
  required double pixels,
}) {
  if (axis != Axis.vertical) return null;
  if (pixels <= 0) return true;
  switch (direction) {
    case ScrollDirection.reverse:
      return pixels > kToolbarHeight ? false : null;
    case ScrollDirection.forward:
      return true;
    case ScrollDirection.idle:
      return null;
  }
}
