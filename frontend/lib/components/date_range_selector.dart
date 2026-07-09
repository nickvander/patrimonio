import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

enum DateRange { oneMonth, yearToDate, oneYear, fiveYears, all }

class DateRangeSelector extends StatelessWidget {
  final DateRange selectedRange;
  final Function(DateRange) onRangeChanged;

  const DateRangeSelector({
    super.key,
    required this.selectedRange,
    required this.onRangeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width < 420 ? 10.0 : 16.0;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSegment(
              context, l.lwRangeOneMonth, DateRange.oneMonth, horizontalPadding),
          _buildSegment(context, l.lwRangeYearToDate, DateRange.yearToDate,
              horizontalPadding),
          _buildSegment(
              context, l.lwRangeOneYear, DateRange.oneYear, horizontalPadding),
          _buildSegment(
              context, l.lwRangeFiveYears, DateRange.fiveYears, horizontalPadding),
          _buildSegment(context, l.lwRangeAll, DateRange.all, horizontalPadding),
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
    return GestureDetector(
      onTap: () => onRangeChanged(range),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
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
          style: TextStyle(
            color: isSelected ? context.positive : context.textMuted,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
