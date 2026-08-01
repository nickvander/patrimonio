/// Parse a backend `'YYYY-MM'` month key into its inclusive calendar
/// window: (first day of the month, last day of the month).
///
/// Shared by every "drill into this month" jump (the cash-flow trends
/// chart bar tap, the bell's spending-spike rows) so the string→window
/// conversion lives in exactly one place. Returns null on malformed
/// input (empty string, missing month part, non-numeric or out-of-range
/// month) — callers degrade gracefully instead of crashing on a payload
/// an older/newer server produced.
({DateTime start, DateTime end})? monthWindow(String yyyyMm) {
  final parts = yyyyMm.split('-');
  if (parts.length != 2) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  if (year == null || month == null || month < 1 || month > 12) return null;
  return (
    start: DateTime(year, month, 1),
    // Day 0 of the NEXT month = last day of this one — correct across
    // the December→January rollover (DateTime normalizes month 13).
    end: DateTime(year, month + 1, 0),
  );
}
