/// Locale-aware date rendering for the lending surfaces.
///
/// Loan payloads carry ISO `yyyy-MM-dd` strings. These helpers parse and
/// render them with locale-aware skeletons (`DateFormat.yMMMd` /
/// `DateFormat.MMMd`), which follow the app locale via `syncIntlLocale` —
/// so es-MX reads "1 may 2024" instead of the raw ISO string or a
/// US-ordered "may 1, 2024". Each falls back to the raw input when it
/// doesn't parse, so malformed data never blanks a label.
///
/// Kept Flutter-free so the formatting can be unit-tested directly on the
/// Dart VM (see `test/utils/loan_dates_test.dart`).
library;

import 'package:intl/intl.dart';

/// "2024-05-01" → "May 1, 2024" (en) / "1 may 2024" (es-MX).
String formatIsoDateMedium(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat.yMMMd().format(d);
}

/// "2024-05-01" → "May 1" (en) / "1 may" (es-MX) — for tight pills and
/// schedule columns where the year would crowd out the money.
String formatIsoDateShort(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat.MMMd().format(d);
}
