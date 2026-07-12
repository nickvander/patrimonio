import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// 12-month projected dividend income calendar (contract C4-B).
///
/// Renders the additive `calendar` field of
/// GET /dashboard/holdings/dividends: exactly 12 month buckets starting at
/// the current month, each with a projected USD total and per-symbol
/// entries (already sorted amount-descending by the server). Pure
/// presentation — all cadence math happens backend-side, so this widget
/// never re-derives dates or amounts.
///
/// Layout: a 12-row month bar-list — each row is month label → a bar
/// proportional to the month's projected total (one global scale across
/// all 12 months) → the amount. Tapping an income row expands its full
/// per-payer breakdown inline (one month open at a time); there are no
/// chips, tooltips, or "+N more" overflow. On wide constraints (>= 720 px
/// off the inner LayoutBuilder) the 12 rows split into two side-by-side
/// columns of six. Zero-income months always render (muted em-dash total,
/// empty track) — the dry months are as much the point as the payday
/// ones. The current month gets a subtle accent border. Each collapsed
/// row is a single merged semantics node ("July 2026, $310 expected, KO,
/// ABBV") per the round-3 a11y conventions; expanded payer lines are
/// their own merged nodes so screen readers announce them.
class DividendCalendar extends StatefulWidget {
  /// Raw `calendar` list from the API (C4-B shape).
  final List<dynamic> calendar;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const DividendCalendar({
    super.key,
    required this.calendar,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<DividendCalendar> createState() => _DividendCalendarState();
}

class _DividendCalendarState extends State<DividendCalendar> {
  /// `YYYY-MM` key of the single expanded month, if any. Only one month's
  /// payer breakdown is open at a time.
  String? _expandedKey;

  /// USD figure scaled into the display currency — the exact `_money`
  /// convention of the host dividend-income card.
  String _money(double usd) =>
      widget.currencyFormat.displayMoney(usd * widget.conversionFactor);

  void _toggle(String key) {
    setState(() => _expandedKey = _expandedKey == key ? null : key);
  }

  @override
  Widget build(BuildContext context) {
    final months = widget.calendar
        .whereType<Map>()
        .map((m) => _CalMonth.parse(m.cast<String, dynamic>()))
        .toList();
    if (months.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    // The backend builds the 12 buckets starting at the UTC current month, so
    // the first bucket's key IS "now" server-side. Deriving the accent from it
    // (rather than local DateTime.now()) keeps the highlight correct near a
    // month boundary when the client's local month differs from UTC.
    final currentKey = months.first.key;
    // One global scale: every bar is linear in USD magnitude against the
    // biggest month, so bars compare across both columns on wide layouts.
    // USD values keep the scale invariant under the display conversion factor.
    final maxTotalUsd =
        months.fold<double>(0, (max, m) => m.totalUsd > max ? m.totalUsd : max);

    return LayoutBuilder(builder: (context, constraints) {
      // House rule: responsiveness off the INNER constraint, not the screen.
      final isWide = constraints.maxWidth >= 720;
      final rows = isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _rowColumn(context, l10n, months.take(6).toList(),
                      currentKey, maxTotalUsd),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _rowColumn(context, l10n, months.skip(6).toList(),
                      currentKey, maxTotalUsd),
                ),
              ],
            )
          : _rowColumn(context, l10n, months, currentKey, maxTotalUsd);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          rows,
          const SizedBox(height: 10),
          // Mandatory honesty caption: these are projections from current
          // rate + cadence, not declared dividends.
          Text(
            l10n.calEstimateCaption,
            style: TextStyle(fontSize: 11, color: context.textMuted),
          ),
        ],
      );
    });
  }

  Widget _rowColumn(BuildContext context, AppLocalizations l10n,
      List<_CalMonth> months, String currentKey, double maxTotalUsd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < months.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          _monthRow(context, l10n, months[i], currentKey, maxTotalUsd),
        ],
      ],
    );
  }

  // ---------- one month: collapsed bar row + inline payer breakdown ----------

  Widget _monthRow(BuildContext context, AppLocalizations l10n,
      _CalMonth month, String currentKey, double maxTotalUsd) {
    final isCurrent = month.key == currentKey;
    final isExpanded = _expandedKey == month.key;
    final label = month.label();
    final hasIncome = month.totalUsd > 0 && month.entries.isNotEmpty;
    // Nonzero months keep a 2% minimum sliver so tiny payers stay visible;
    // guard the all-zero calendar (maxTotalUsd == 0) against NaN.
    final widthFactor = maxTotalUsd <= 0
        ? 0.0
        : (month.totalUsd / maxTotalUsd)
            .clamp(hasIncome ? 0.02 : 0.0, 1.0)
            .toDouble();

    // One merged, labelled node per collapsed row — "July 2026, $310
    // expected, KO, ABBV" (round-3 a11y conventions, labels unchanged).
    final semLabel = hasIncome
        ? l10n.calMonthSem(label, _money(month.totalUsd),
            month.entries.map((e) => e.symbol).join(', '))
        : l10n.calMonthSemEmpty(label);

    final collapsedRow = MergeSemantics(
      child: Semantics(
        label: semLabel,
        hint: hasIncome
            ? (isExpanded ? l10n.calCollapseHint : l10n.calExpandHint)
            : null,
        button: hasIncome,
        expanded: hasIncome ? isExpanded : null,
        onTap: hasIncome ? () => _toggle(month.key) : null,
        excludeSemantics: true,
        container: true,
        child: Container(
          key: ValueKey('cal-row-${month.key}'),
          decoration: isCurrent
              ? BoxDecoration(
                  color: context.tileSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: context.accentBorder(context.tealAccent),
                    width: 1.5,
                  ),
                )
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: hasIncome ? () => _toggle(month.key) : null,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isCurrent
                            ? context.tealAccent
                            : context.textSubtle,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: context.tint(0.06),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: FractionallySizedBox(
                        key: ValueKey('cal-bar-${month.key}'),
                        alignment: AlignmentDirectional.centerStart,
                        widthFactor: widthFactor,
                        child: Container(
                          decoration: BoxDecoration(
                            color: context.tealAccent
                                .withValues(alpha: isCurrent ? 0.95 : 0.45),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    // Zero months render a muted em-dash, never disappear —
                    // seeing the dry months is the point of the calendar.
                    hasIncome ? _money(month.totalUsd) : '—',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color:
                          hasIncome ? context.textPrimary : context.textFaint,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (hasIncome)
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: context.textMuted,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!isExpanded || !hasIncome) return collapsedRow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        collapsedRow,
        // Inline payer breakdown — ALL entries, server order (amount-desc).
        // Sits OUTSIDE the collapsed row's excludeSemantics node so each
        // line is announced; indented 84px past the row's 10px gutter to
        // align with the bar start.
        Padding(
          padding: const EdgeInsets.only(left: 10 + 84, right: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final e in month.entries)
                MergeSemantics(
                  child: SizedBox(
                    height: 28,
                    child: Row(
                      children: [
                        Text(
                          e.symbol,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.calEstExDate(e.dateLabel()),
                            style: TextStyle(
                              fontSize: 11,
                              color: context.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _money(e.amountUsd),
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------- parsed C4-B rows ----------

class _CalEntry {
  final String symbol;
  final String estDate;
  final double amountUsd;

  const _CalEntry(this.symbol, this.estDate, this.amountUsd);

  /// "Jul 14, 2026" — falls back to the raw string for unparseable input.
  String dateLabel() {
    final parsed = DateTime.tryParse(estDate);
    return parsed == null ? estDate : DateFormat.yMMMd().format(parsed);
  }
}

class _CalMonth {
  /// `YYYY-MM` bucket key, straight from the API.
  final String key;
  final double totalUsd;
  final List<_CalEntry> entries;

  const _CalMonth(this.key, this.totalUsd, this.entries);

  factory _CalMonth.parse(Map<String, dynamic> m) {
    final entries = ((m['entries'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => _CalEntry(
              (e['symbol'] ?? '').toString(),
              (e['est_date'] ?? '').toString(),
              (e['amount_usd'] as num?)?.toDouble() ?? 0.0,
            ))
        .where((e) => e.symbol.isNotEmpty)
        .toList();
    return _CalMonth(
      (m['month'] ?? '').toString(),
      (m['total_usd'] as num?)?.toDouble() ?? 0.0,
      entries,
    );
  }

  /// "Jul 2026" — parsed off the bucket key's first day.
  String label() {
    final parsed = DateTime.tryParse('$key-01');
    return parsed == null ? key : DateFormat.yMMM().format(parsed);
  }
}
