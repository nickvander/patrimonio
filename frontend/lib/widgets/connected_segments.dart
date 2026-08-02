import 'package:flutter/material.dart';

import '../utils/theme_colors.dart';

/// One option in a [ConnectedSegments] group.
class ConnectedSegment<T> {
  const ConnectedSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;

  /// Optional leading icon (the dashboard theme picker uses one; the
  /// transaction filter groups don't).
  final IconData? icon;
}

/// M3 Expressive "connected button group" — the house single-select
/// control for small fixed option sets, extracted from the dashboard
/// theme picker's inline `seg(...)` builder so every surface shares one
/// implementation instead of forking copies.
///
/// Visual recipe (deliberately NOT `SegmentedButton`, whose shared
/// outline + checkmark read as dated chrome and whose intrinsic sizing
/// needs a scroll guard): equal-flex segments filling the available
/// width, 44dp tall, 2px gaps, no outline. Resting segments sit on a
/// quiet `tint(0.05)` fill; the selected segment morphs (200ms easeOut)
/// into a filled `secondaryContainer` pill with fully-rounded corners —
/// outer ends are always 22, inner corners sit at 8 until selection
/// rounds them. Selection is mirrored into the semantics tree.
///
/// Single-select semantics: tapping a segment calls [onSelected] with its
/// value (including re-taps of the current selection — callers that
/// persist on change may want to short-circuit those).
class ConnectedSegments<T> extends StatelessWidget {
  const ConnectedSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
  });

  final List<ConnectedSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          _segment(
            context,
            segments[i],
            first: i == 0,
            last: i == segments.length - 1,
          ),
        ],
      ],
    );
  }

  Widget _segment(
    BuildContext context,
    ConnectedSegment<T> segment, {
    required bool first,
    required bool last,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = segment.value == selected;
    // Outer ends stay pill-round; inner corners sit at 8 until selection
    // morphs the segment fully round.
    final radius = BorderRadius.horizontal(
      left: Radius.circular(isSelected || first ? 22 : 8),
      right: Radius.circular(isSelected || last ? 22 : 8),
    );
    return Expanded(
      child: Semantics(
        selected: isSelected,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          height: 44,
          decoration: BoxDecoration(
            color: isSelected ? scheme.secondaryContainer : context.tint(0.05),
            borderRadius: radius,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: () => onSelected(segment.value),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (segment.icon != null) ...[
                      Icon(
                        segment.icon,
                        size: 18,
                        color: isSelected
                            ? scheme.onSecondaryContainer
                            : context.textSubtle,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        segment.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: isSelected
                              ? scheme.onSecondaryContainer
                              : context.textSubtle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
