import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

enum DateRange { oneMonth, yearToDate, oneYear, fiveYears, all }

class DateRangeSelector extends StatelessWidget {
  final DateRange selectedRange;
  final Function(DateRange) onRangeChanged;

  /// Share the available width equally between the five segments instead of
  /// letting each one size to its own label.
  ///
  /// WHY IT'S OPT-IN. Content-sized is right when the selector sits beside
  /// something else — a card title on a wide header, the benchmark picker on
  /// the Performance card — where filling would either stretch a five-segment
  /// bar across a 1400px card or fight its neighbour for the row.
  ///
  /// It is wrong when the selector is the only thing on its line, which is how
  /// the phone layout places it (in-card, under the plot it controls). There,
  /// `MainAxisSize.min` left a stubby pill hugging ~60% of the card with dead
  /// space to its right, and — because "YTD" is wider than "1M" — segments of
  /// five different widths. Same rule the action buttons settled on: touch-width
  /// layouts go full-bleed, pointer-width layouts size to the label.
  ///
  /// Callers must not wrap a filling selector in a horizontally-scrolling
  /// parent: `Expanded` needs a bounded width. It doesn't need one anyway —
  /// every label is 2-4 characters in both locales, so a fifth of a phone card
  /// is far more room than any of them asks for.
  final bool fill;

  /// Width this selector may occupy, taken from the CALLER's `LayoutBuilder`
  /// constraint — never `MediaQuery`.
  ///
  /// Only the content-sized ([fill] == false) layout consults it, to tighten
  /// each segment's horizontal padding on a phone-narrow row. It has to come
  /// from the caller: content-sized callers hand this widget an *unbounded*
  /// width (the net-worth header wraps it in a horizontal scroller, and a
  /// non-flex child of a `Row` is laid out with `maxWidth: infinity`), so a
  /// `LayoutBuilder` in here would measure infinity rather than the row.
  ///
  /// Null (or unbounded) means "no reason to tighten" → the roomy padding.
  final double? availableWidth;

  const DateRangeSelector({
    super.key,
    required this.selectedRange,
    required this.onRangeChanged,
    this.fill = false,
    this.availableWidth,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Only consulted when sizing to content; a filling selector takes its
    // width from the parent and centres the label in it. The narrow test is
    // the row this selector was given ([availableWidth]), not the screen —
    // the same card is narrow in a column on a wide window and roomy on a
    // wide sheet on a phone.
    final horizontalPadding = (availableWidth ?? double.infinity) < 420
        ? 10.0
        : 16.0;

    final segments = <(String, DateRange)>[
      (l.lwRangeOneMonth, DateRange.oneMonth),
      (l.lwRangeYearToDate, DateRange.yearToDate),
      (l.lwRangeOneYear, DateRange.oneYear),
      (l.lwRangeFiveYears, DateRange.fiveYears),
      (l.lwRangeAll, DateRange.all),
    ];

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final (label, range) in segments)
            if (fill)
              Expanded(
                child: _buildSegment(context, label, range, horizontalPadding),
              )
            else
              _buildSegment(context, label, range, horizontalPadding),
        ],
      ),
    );
  }

  Widget _buildSegment(
    BuildContext context,
    String label,
    DateRange range,
    double horizontalPadding,
  ) {
    final isSelected = selectedRange == range;
    // InkWell (focusable, keyboard-activatable, ripple) with a guaranteed
    // >=44dp hit height — the visual pill inside stays its compact HEIGHT
    // whether or not it fills the width.
    return InkWell(
      onTap: () => onRangeChanged(range),
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            // Filling: take the whole segment and centre the label in it, so
            // the selected pill reads as one cell of a segmented control
            // rather than a chip floating in it.
            width: fill ? double.infinity : null,
            alignment: fill ? Alignment.center : null,
            padding: EdgeInsets.symmetric(
              horizontal: fill ? 4 : horizontalPadding,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? context.accentSoft(context.positive)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected ? context.positive : context.textMuted,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
