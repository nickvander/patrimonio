/// Helpers for the spending-by-category "average per month" figure.
///
/// The `/dashboard/spending-by-category` window is N calendar months ending
/// with the **in-progress current month** (backend:
/// `t.date >= DATE_TRUNC('month', CURRENT_DATE) - (N - 1) months`).
library;

/// The number of months to divide a spending-window total by to get the
/// per-month average.
///
/// Uses the REQUESTED window length ([windowMonths]) — not the number of
/// months that happened to have spending. The backend's `months` list only
/// carries populated buckets, so dividing by its length inflated sparse
/// categories (a single $4.50 purchase in a 12-month window rendered as
/// ~$6/mo instead of ~$0.39/mo).
///
/// The current month is still in progress, so it counts as the fraction of
/// it elapsed so far rather than a whole slot — a half-elapsed month's spend
/// shouldn't be spread across a full one. The result is therefore always > 0
/// (`now.day >= 1`), even for a 1-month window on the 1st.
double spendingWindowDivisor(int windowMonths, DateTime now) {
  // Day 0 of next month == last day of this month (handles 28/29/30/31).
  final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
  final elapsedFraction = now.day / daysInMonth;
  final priorFullMonths = windowMonths < 1 ? 0 : windowMonths - 1;
  return priorFullMonths + elapsedFraction;
}
