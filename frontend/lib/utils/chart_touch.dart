import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'theme_colors.dart';

/// The app-standard line-chart hover: full-width X snapping
/// (touchSpotThreshold 100000), vertical guide + halo dot indicator,
/// token-colored tooltip. Mirrors net_worth_card.dart's LineTouchData so the
/// remaining charts adopt the identical feel without copy-paste drift.
///
/// The three headline charts (net worth, projections, instrument sheet)
/// predate this helper and deliberately keep their own inline copies this
/// round — do not refactor them here; the contract is that this function
/// stays byte-equivalent in behavior to net_worth_card.dart:570-612.
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
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.35),
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
