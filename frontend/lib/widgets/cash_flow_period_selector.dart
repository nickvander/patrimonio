import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/buttons.dart';
import 'connected_segments.dart';

/// Period the Cash Flow tab's headline cards summarize. Drives a
/// calendar-month window passed to the trends endpoint:
///   thisMonth   -> 1 month  (current)
///   lastMonth   -> 2 months (so the prior month + a vs-comparison are present)
///   threeMonths -> 3 months (aggregated)
///   ytd         -> Jan..current of this year (aggregated)
enum CashFlowPeriod { thisMonth, lastMonth, threeMonths, ytd }

/// The Cash flow tab's period picker — the house connected button group
/// ([ConnectedSegments]) at every width, extracted from the dashboard's
/// inline builder so it can be widget-tested in isolation.
///
/// One row, no horizontal scroll (the old narrow branch was a scrolling
/// `ChoiceChip` row that hid the selected period off-screen). Below
/// [_fullLabelMinWidth] the labels swap to compact bilingual forms
/// because the full strings do not fit a phone-width segment: measured in
/// Inter at the group's 13.5px, "En lo que va del año" is ~130px and
/// "Últimos 3 meses" ~108px, while four equal-flex segments give only
/// ~88px at a 390px screen (~80px at 360px). The compact set's longest
/// label ("This month", ~74px) fits the 360px case with slack. At and
/// above the breakpoint each segment is at least ~138px, so the full
/// labels fit both locales without ellipsizing.
class CashFlowPeriodSelector extends StatelessWidget {
  const CashFlowPeriodSelector({
    super.key,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final CashFlowPeriod selected;

  /// False while a period fetch is in flight — the group renders
  /// non-interactive, the same window the old chips' null `onSelected`
  /// provided.
  final bool enabled;

  /// Called when a *different* period is picked; re-tapping the current
  /// selection is a no-op (never refetches).
  final ValueChanged<CashFlowPeriod> onChanged;

  /// Available width below which the compact labels are used, and the
  /// group's width cap above it. The longest full label ("En lo que va
  /// del año", ~130px at 13.5px w700) needs a ~136px segment; four
  /// segments plus the 2px gaps ⇒ ~550px, rounded up to the shared
  /// compact-layout threshold (this measurement is where that constant's
  /// value comes from). The old 480px cap ellipsized that es-MX label
  /// even on desktop.
  static const double _fullLabelMinWidth = kCompactLayoutBelow;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < _fullLabelMinWidth;
        return Align(
          alignment: Alignment.centerLeft,
          // ConnectedSegments is built of Expandeds, so it takes a width
          // cap instead of a scroll guard (its labels would ellipsize
          // rather than overflow); the cap keeps desktop segments from
          // stretching across the whole content column.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _fullLabelMinWidth),
            child: ConnectedSegments<CashFlowPeriod>(
              segments: [
                ConnectedSegment(
                  value: CashFlowPeriod.thisMonth,
                  label: l.cfPeriodThisMonth,
                ),
                ConnectedSegment(
                  value: CashFlowPeriod.lastMonth,
                  label: compact
                      ? l.cfPeriodLastMonthShort
                      : l.cfPeriodLastMonth,
                ),
                ConnectedSegment(
                  value: CashFlowPeriod.threeMonths,
                  label: compact ? l.cfPeriod3MonthsShort : l.cfPeriod3Months,
                ),
                ConnectedSegment(
                  value: CashFlowPeriod.ytd,
                  label: compact ? l.cfPeriodYtdShort : l.cfPeriodYtd,
                ),
              ],
              selected: selected,
              enabled: enabled,
              onSelected: (value) {
                // Re-selecting the current period must not refetch.
                if (value == selected) return;
                onChanged(value);
              },
            ),
          ),
        );
      },
    );
  }
}
