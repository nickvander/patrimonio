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
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSegment('1M', DateRange.oneMonth),
          _buildSegment('YTD', DateRange.yearToDate),
          _buildSegment('1Y', DateRange.oneYear),
          _buildSegment('5Y', DateRange.fiveYears),
          _buildSegment('ALL', DateRange.all),
        ],
      ),
    );
  }

  Widget _buildSegment(String label, DateRange range) {
    final isSelected = selectedRange == range;
    return GestureDetector(
      onTap: () => onRangeChanged(range),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.greenAccent.withOpacity(0.2) : Colors.transparent,
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
