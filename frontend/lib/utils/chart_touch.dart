import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'theme_colors.dart';

/// True when [event] must clear transient tooltip/indicator state.
///
/// fl_chart's own `FlTouchEvent.isInterestedForInteractions` deliberately
/// keeps [FlTapUpEvent] "interested" on web so a desktop click doesn't blank
/// the hover tooltip. But that carve-out also applies to a *finger* on mobile
/// web, where the tap-up is the last event the chart ever receives — touch
/// pointers emit no [FlPointerExitEvent] — so the tooltip stayed pinned
/// forever (the prod TWR-chart bug). House standard: the tooltip is a
/// transient scrub indicator — visible while hovering (mouse/trackpad) or
/// while the finger is down, dismissed on exit / release / gesture end.
/// A tap-up therefore dismisses unless it came from a pointer that can hover
/// (mouse/trackpad), whose tooltip a later exit event will clear.
bool chartTouchDismisses(FlTouchEvent event) {
  // Whatever fl_chart's built-in gating would clear on, we clear on — the
  // predicate is only ever STRICTER than the built-in one (it adds the
  // touch/stylus tap-up case), never stickier.
  if (!event.isInterestedForInteractions) return true;
  if (event is FlTapUpEvent) {
    final kind = event.details.kind;
    return kind != PointerDeviceKind.mouse &&
        kind != PointerDeviceKind.trackpad;
  }
  // Flutter web's pointer pipeline synthesizes a hover event for a
  // just-lifted *touch* pointer immediately after the tap-up handled above —
  // and a touch pointer will never send the exit event that later clears a
  // real mouse hover, so honoring it would re-pin the tooltip forever
  // (reproduced on the prod TWR chart). Hover/enter may only show a tooltip
  // when the pointer can actually hover.
  if (event is FlPointerHoverEvent) {
    return !_kindCanHover(event.event.kind);
  }
  if (event is FlPointerEnterEvent) {
    return !_kindCanHover(event.event.kind);
  }
  return false;
}

bool _kindCanHover(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

/// The [PointerDeviceKind] carried by [event], or null when the event type
/// doesn't expose one (pan down/update/end, long-press, cancels) — callers
/// keep their last known kind in that case.
PointerDeviceKind? chartEventPointerKind(FlTouchEvent event) {
  return switch (event) {
    FlTapDownEvent(:final details) => details.kind,
    FlTapUpEvent(:final details) => details.kind,
    FlPanStartEvent(:final details) => details.kind,
    FlPointerEnterEvent(:final event) => event.kind,
    FlPointerHoverEvent(:final event) => event.kind,
    FlPointerExitEvent(:final event) => event.kind,
    _ => null,
  };
}

/// True when a tooltip driven by a pointer of [kind] must render pinned to
/// the top of the chart box (fl_chart's `showOnTopOfTheChartBoxArea`) instead
/// of as a popover beside the touched spot: a finger or stylus *covers* the
/// spot it is scrubbing, so the near-spot popover lands directly under it
/// (the prod TWR-chart complaint). The top-of-box readout is the touch
/// counterpart of the Robinhood-style scrub whose full-width X snapping
/// [standardLineTouch] already imitates. Mouse/trackpad keep the popover.
bool chartTooltipPinsToTop(PointerDeviceKind kind) => !_kindCanHover(kind);

/// Platform seed used before any kind-carrying event arrives: the very first
/// touch emits a kind-less [FlPanDownEvent] before the kind-carrying
/// tap-down/pan-start, so a hover-default on a phone would flash the tooltip
/// under the finger for that first frame. Phones/tablets are finger-first;
/// everything else defaults to the hover popover. Either way the first
/// kind-carrying event corrects the guess (see [chartEventPointerKind]).
bool get chartTooltipDefaultPinsToTop => switch (defaultTargetPlatform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => true,
  _ => false,
};

/// Rebuilds [base] with `showOnTopOfTheChartBoxArea: pinned`, returning
/// [base] itself when the flag already matches. Manual full-field copy
/// because [LineTouchTooltipData] has no `copyWith` in fl_chart 0.70.2 —
/// if fl_chart grows one, replace this body with it.
LineTouchTooltipData lineTooltipPinnedToTop(
  LineTouchTooltipData base, {
  required bool pinned,
}) {
  if (base.showOnTopOfTheChartBoxArea == pinned) return base;
  return LineTouchTooltipData(
    tooltipRoundedRadius: base.tooltipRoundedRadius,
    tooltipPadding: base.tooltipPadding,
    tooltipMargin: base.tooltipMargin,
    tooltipHorizontalAlignment: base.tooltipHorizontalAlignment,
    tooltipHorizontalOffset: base.tooltipHorizontalOffset,
    maxContentWidth: base.maxContentWidth,
    getTooltipItems: base.getTooltipItems,
    getTooltipColor: base.getTooltipColor,
    fitInsideHorizontally: base.fitInsideHorizontally,
    fitInsideVertically: base.fitInsideVertically,
    showOnTopOfTheChartBoxArea: pinned,
    rotateAngle: base.rotateAngle,
    tooltipBorder: base.tooltipBorder,
  );
}

/// The app-standard line-chart hover: full-width X snapping
/// (touchSpotThreshold 100000), vertical guide + halo dot indicator,
/// token-colored tooltip. Mirrors net_worth_card.dart's LineTouchData so the
/// remaining charts adopt the identical feel without copy-paste drift.
///
/// The three headline charts (net worth, projections, instrument sheet)
/// predate this helper and deliberately keep their own inline copies this
/// round — do not refactor them here; the contract is that this function
/// stays byte-equivalent in behavior to the inline `LineTouchData` in
/// net_worth_card.dart's `_renderLineChart`.
LineTouchData standardLineTouch(
  BuildContext context, {
  required List<LineTooltipItem?> Function(BuildContext, List<LineBarSpot>)
  items,
  bool showIndicator = true,
}) {
  return LineTouchData(
    // Snap-to-nearest-x feel: a very large threshold makes the chart always
    // pick the closest sample to the cursor's X regardless of vertical
    // distance. That's the canonical Robinhood / Mint / Personal Capital
    // interaction — the cursor doesn't have to land on the line for a
    // tooltip to fire. Combined with the vertical guide drawn by
    // `getTouchedSpotIndicator` below, hover feels continuous instead of
    // "you have to find the sample".
    touchSpotThreshold: 100000,
    distanceCalculator: (touchPoint, spotPixelCoordinates) =>
        (touchPoint.dx - spotPixelCoordinates.dx).abs(),
    handleBuiltInTouches: true,
    getTouchedSpotIndicator: (barData, spotIndexes) {
      // Paint a vertical guide line and a ring-bordered dot at each touched
      // spot; without it, threshold-snapped hover has no visual anchor.
      return spotIndexes.map((idx) {
        if (!showIndicator) {
          return const TouchedSpotIndicatorData(
            FlLine(color: Colors.transparent, strokeWidth: 0),
            FlDotData(show: false),
          );
        }
        return TouchedSpotIndicatorData(
          FlLine(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.35),
            strokeWidth: 1,
          ),
          FlDotData(
            show: true,
            getDotPainter: (spot, percent, bar, i) => FlDotCirclePainter(
              radius: 5,
              color: barData.color ?? context.positive,
              strokeWidth: 3,
              strokeColor: Theme.of(context).colorScheme.surface,
            ),
          ),
        );
      }).toList();
    },
    touchTooltipData: LineTouchTooltipData(
      // tooltipSurface is the brightness-opposite of the active surface:
      // dark popovers in light mode, light popovers in dark mode. All text
      // spans inside `items` must use the tooltipOnSurface family.
      getTooltipColor: (touchedSpot) => context.tooltipSurface,
      tooltipRoundedRadius: 12,
      // Keep the popover on-screen. Charts flush against the viewport edge
      // (e.g. the account-panel balance sparkline) would otherwise clip the
      // tooltip mid-word at the right edge.
      fitInsideHorizontally: true,
      fitInsideVertically: true,
      getTooltipItems: (touchedSpots) => items(context, touchedSpots),
    ),
  );
}

/// A live scrub reading published by [TransientTooltipLineChart.onScrub]:
/// the spots currently under the pointer (y-descending — the same order the
/// tooltip rows use, so `barIndex` lookups match the tooltip's) plus whether
/// the pointer driving them is a finger/stylus.
///
/// A host uses it to render the reading OUTSIDE the plot (see
/// [TransientTooltipLineChart.suppressTooltipOnTouch]); `null` is published
/// the moment the scrub ends, so a host can never keep a stale value on
/// screen after the finger lifts.
@immutable
class ChartScrub {
  const ChartScrub({required this.spots, required this.isTouch});

  /// Touched spots, sorted y-descending.
  final List<LineBarSpot> spots;

  /// True when the active pointer is a finger/stylus (i.e. one that covers
  /// what it touches), false for mouse/trackpad.
  final bool isTouch;
}

/// Drop-in replacement for `LineChart(data)` whose tooltip is a *transient*
/// scrub indicator (the projections-chart pattern, generalized): shown while
/// hovering or while the finger is down, cleared whenever
/// [chartTouchDismisses] says so — never pinned after the finger lifts.
///
/// fl_chart's built-in touch handling can't deliver that on mobile web (see
/// [chartTouchDismisses]), so this widget owns the touched-spot state
/// instead: it forces `handleBuiltInTouches: false` and re-applies the state
/// through `showingTooltipIndicators` + per-bar `showingIndicators`, sorted
/// y-descending exactly like the built-in handler — tooltip content, order
/// and styling are unchanged. A `touchCallback` already present on [data]
/// (e.g. tap-to-drill) is still invoked first, like fl_chart itself does.
///
/// It also owns tooltip *placement*: touch/stylus pointers pin the readout
/// to the top of the chart box, mouse/trackpad keep the near-spot popover
/// (see [chartTooltipPinsToTop]) — so every wrapped chart is pointer-kind
/// aware for free. Charts too SHORT for the pinned readout to clear the hand
/// hoist the reading out of the plot entirely instead: see [onScrub] +
/// [suppressTooltipOnTouch].
class TransientTooltipLineChart extends StatefulWidget {
  const TransientTooltipLineChart({
    super.key,
    required this.data,
    this.onScrub,
    this.suppressTooltipOnTouch = false,
  });

  /// The chart data, built exactly as it would be for a raw [LineChart].
  final LineChartData data;

  /// Called whenever the scrubbed spots (or the pointer kind driving them)
  /// change, and with `null` when the scrub ends. Lets a host mirror the
  /// reading into its own header — the Robinhood / Copilot scrub pattern.
  ///
  /// Fires for mouse/trackpad too, with [ChartScrub.isTouch] false, so a host
  /// that only wants the touch case can ignore those and leave desktop
  /// behavior untouched. Invoked from the chart's touch callback (never
  /// during build), and deduplicated: repeated events describing the same
  /// spots don't re-notify.
  final void Function(ChartScrub? scrub)? onScrub;

  /// When true, a TOUCH/stylus scrub draws no in-chart tooltip at all — only
  /// the vertical guide + highlighted dot, which stay as the position
  /// feedback. For a chart ~120px tall (the performance card on a phone) a
  /// 3-line tooltip pinned to the top of the box still lands under the
  /// fingertip; the honest fix is to move the numbers out of the plot, so
  /// hosts that set this MUST render the reading from [onScrub] somewhere
  /// clear of the hand (their header).
  ///
  /// Mouse/trackpad are unaffected — a cursor doesn't occlude the spot it
  /// points at, so the near-spot popover stays exactly as it is today.
  final bool suppressTooltipOnTouch;

  @override
  State<TransientTooltipLineChart> createState() =>
      _TransientTooltipLineChartState();
}

class _TransientTooltipLineChartState extends State<TransientTooltipLineChart> {
  /// Currently touched spots (sorted y-descending); null/empty = no tooltip.
  List<LineBarSpot>? _touched;

  /// True when the active pointer is a finger/stylus — one that COVERS the
  /// spot it touches. Drives both the top-pinned tooltip placement and
  /// [TransientTooltipLineChart.suppressTooltipOnTouch]. Seeded per platform,
  /// then tracks the active pointer's kind so runtime kind switches
  /// (touchscreen laptop, mouse plugged into a tablet) flip behavior live.
  late bool _touchPointer = chartTooltipDefaultPinsToTop;

  /// Identity of the last reading handed to [TransientTooltipLineChart
  /// .onScrub] (null = "already published no-scrub"), so a drag that keeps
  /// landing on the same spot doesn't re-notify the host every event.
  String? _lastScrubKey;

  /// True when [spots] describes the same touched positions as the current
  /// state — used to skip no-op setState calls on every hover tick.
  bool _sameTouched(List<LineBarSpot> spots) {
    final cur = _touched;
    if (cur == null || cur.length != spots.length) return false;
    for (var i = 0; i < spots.length; i++) {
      if (cur[i].barIndex != spots[i].barIndex ||
          cur[i].spotIndex != spots[i].spotIndex) {
        return false;
      }
    }
    return true;
  }

  /// Publishes [scrub] to the host, skipping repeats. The key covers the
  /// touched positions and the pointer kind — exactly what the host's
  /// rendering depends on.
  void _notifyScrub(ChartScrub? scrub) {
    final onScrub = widget.onScrub;
    if (onScrub == null) return;
    final key = scrub == null
        ? null
        : '${scrub.isTouch}:'
              '${scrub.spots.map((s) => '${s.barIndex}/${s.spotIndex}').join(',')}';
    if (key == _lastScrubKey) return;
    _lastScrubKey = key;
    onScrub(scrub);
  }

  void _onTouch(FlTouchEvent event, LineTouchResponse? response) {
    widget.data.lineTouchData.touchCallback?.call(event, response);
    final kind = chartEventPointerKind(event);
    final touch = kind == null ? _touchPointer : chartTooltipPinsToTop(kind);
    final spots = response?.lineBarSpots;
    if (chartTouchDismisses(event) || spots == null || spots.isEmpty) {
      if (_touched != null) {
        setState(() {
          _touched = null;
          _touchPointer = touch;
        });
      } else {
        // No tooltip visible — remember the kind without a rebuild.
        _touchPointer = touch;
      }
      // The scrub is over: the host must drop its reading in the SAME frame
      // the finger lifts, or a stale value survives the gesture.
      _notifyScrub(null);
      return;
    }
    // Same y-descending order the built-in handler used, so the tooltip
    // rows / anchor spot are unchanged.
    final sorted = List<LineBarSpot>.of(spots)
      ..sort((a, b) => b.y.compareTo(a.y));
    if (!_sameTouched(sorted) || touch != _touchPointer) {
      setState(() {
        _touched = sorted;
        _touchPointer = touch;
      });
    }
    _notifyScrub(ChartScrub(spots: sorted, isTouch: touch));
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.data;
    // Drop any stored spot that no longer points inside the current bars
    // (range switched, series toggled, fewer samples…).
    final touched = <LineBarSpot>[
      for (final s in _touched ?? const <LineBarSpot>[])
        if (s.barIndex < raw.lineBarsData.length &&
            s.spotIndex < raw.lineBarsData[s.barIndex].spots.length)
          s,
    ];
    // The host renders this scrub outside the plot, so drawing a tooltip
    // under the finger as well would be the very occlusion it fixes. The
    // per-bar `showingIndicators` below are untouched: the vertical guide
    // and the highlighted dot REMAIN — they're the position feedback that
    // replaces the tooltip (fl_chart paints indicators from the bars and
    // tooltips from `showingTooltipIndicators`, independently).
    final hideTooltip = widget.suppressTooltipOnTouch && _touchPointer;
    return LineChart(
      raw.copyWith(
        lineBarsData: [
          for (var i = 0; i < raw.lineBarsData.length; i++)
            raw.lineBarsData[i].copyWith(
              showingIndicators: [
                for (final s in touched)
                  if (s.barIndex == i) s.spotIndex,
              ],
            ),
        ],
        showingTooltipIndicators: touched.isEmpty || hideTooltip
            ? const []
            : [ShowingTooltipIndicators(touched)],
        lineTouchData: raw.lineTouchData.copyWith(
          handleBuiltInTouches: false,
          touchCallback: _onTouch,
          // Touch/stylus scrubs read from the top of the chart box so the
          // tooltip is never under the finger; mouse/trackpad keep the
          // near-spot popover ([chartTooltipPinsToTop]).
          touchTooltipData: lineTooltipPinnedToTop(
            raw.lineTouchData.touchTooltipData,
            pinned: _touchPointer,
          ),
        ),
      ),
    );
  }
}

/// [TransientTooltipLineChart]'s counterpart for [BarChart]: the built-in
/// bar tooltip pins after a finger lifts on mobile web for the same reason
/// (see [chartTouchDismisses]), so this widget owns the touched-bar state
/// and re-applies it via the touched group's `showingTooltipIndicators`.
/// Tooltip content/styling are untouched, and a `touchCallback` already on
/// [data] (e.g. the trends chart's tap-to-filter) is still invoked first.
class TransientTooltipBarChart extends StatefulWidget {
  const TransientTooltipBarChart({super.key, required this.data});

  /// The chart data, built exactly as it would be for a raw [BarChart].
  final BarChartData data;

  @override
  State<TransientTooltipBarChart> createState() =>
      _TransientTooltipBarChartState();
}

class _TransientTooltipBarChartState extends State<TransientTooltipBarChart> {
  /// Currently touched bar; null = no tooltip.
  int? _groupIndex;
  int? _rodIndex;

  void _onTouch(FlTouchEvent event, BarTouchResponse? response) {
    widget.data.barTouchData.touchCallback?.call(event, response);
    final spot = response?.spot;
    if (chartTouchDismisses(event) || spot == null) {
      if (_groupIndex != null) {
        setState(() {
          _groupIndex = null;
          _rodIndex = null;
        });
      }
      return;
    }
    if (_groupIndex != spot.touchedBarGroupIndex ||
        _rodIndex != spot.touchedRodDataIndex) {
      setState(() {
        _groupIndex = spot.touchedBarGroupIndex;
        _rodIndex = spot.touchedRodDataIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.data;
    return BarChart(
      raw.copyWith(
        barGroups: [
          for (var i = 0; i < raw.barGroups.length; i++)
            raw.barGroups[i].copyWith(
              showingTooltipIndicators: [
                // Bounds-checked against the current data (bar counts change
                // when the month range or category mix does).
                if (i == _groupIndex &&
                    _rodIndex != null &&
                    _rodIndex! >= 0 &&
                    _rodIndex! < raw.barGroups[i].barRods.length)
                  _rodIndex!,
              ],
            ),
        ],
        barTouchData: raw.barTouchData.copyWith(
          handleBuiltInTouches: false,
          touchCallback: _onTouch,
        ),
      ),
    );
  }
}
