import 'package:flutter/material.dart';

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
          _buildSegment('1M', DateRange.oneMonth, horizontalPadding),
          _buildSegment('YTD', DateRange.yearToDate, horizontalPadding),
          _buildSegment('1Y', DateRange.oneYear, horizontalPadding),
          _buildSegment('5Y', DateRange.fiveYears, horizontalPadding),
          _buildSegment('ALL', DateRange.all, horizontalPadding),
        ],
      ),
    );
  }

  Widget _buildSegment(
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
              ? Colors.greenAccent.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.greenAccent : Colors.white70,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
