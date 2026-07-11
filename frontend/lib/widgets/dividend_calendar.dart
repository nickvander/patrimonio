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
/// Layout: a 3×4 month grid on wide surfaces (>= 720 px), a vertical
/// 12-row list below that. Zero-income months always render (muted em-dash
/// total) — the dry months are as much the point as the payday ones. The
/// current month gets a subtle accent border. Each month cell is a single
/// merged semantics node ("July 2026, $310 expected, KO, ABBV") per the
/// round-3 a11y conventions.
class DividendCalendar extends StatelessWidget {
  /// Raw `calendar` list from the API (C4-B shape).
  final List<dynamic> calendar;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Chips shown per month before collapsing into a "+N more" chip.
  static const int _maxChips = 3;

  const DividendCalendar({
    super.key,
    required this.calendar,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  /// USD figure scaled into the display currency — the exact `_money`
  /// convention of the host dividend-income card.
  String _money(double usd) => currencyFormat.displayMoney(usd * conversionFactor);

  @override
  Widget build(BuildContext context) {
    final months = calendar
        .whereType<Map>()
        .map((m) => _CalMonth.parse(m.cast<String, dynamic>()))
        .toList();
    if (months.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 720;
    // The backend builds the 12 buckets starting at the UTC current month, so
    // the first bucket's key IS "now" server-side. Deriving the accent from it
    // (rather than local DateTime.now()) keeps the highlight correct near a
    // month boundary when the client's local month differs from UTC.
    final currentKey = months.first.key;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isWide)
          _grid(context, l10n, months, currentKey)
        else
          _list(context, l10n, months, currentKey),
        const SizedBox(height: 10),
        // Mandatory honesty caption: these are projections from current
        // rate + cadence, not declared dividends.
        Text(
          l10n.calEstimateCaption,
          style: TextStyle(fontSize: 11, color: context.textMuted),
        ),
      ],
    );
  }

  // ---------- wide: 3×4 grid ----------

  Widget _grid(BuildContext context, AppLocalizations l10n,
      List<_CalMonth> months, String currentKey) {
    const columns = 3;
    final rows = (months.length / columns).ceil();
    return Column(
      children: [
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) const SizedBox(height: 8),
          // IntrinsicHeight + stretch keeps every cell in a row the same
          // height (a real grid) without clipping a month that needs an
          // extra chip run.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: 8),
                  Expanded(
                    child: r * columns + c < months.length
                        ? _monthCell(context, l10n, months[r * columns + c],
                            currentKey)
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ---------- narrow: vertical 12-row list ----------

  Widget _list(BuildContext context, AppLocalizations l10n,
      List<_CalMonth> months, String currentKey) {
    return Column(
      children: [
        for (var i = 0; i < months.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _monthCell(context, l10n, months[i], currentKey),
        ],
      ],
    );
  }

  // ---------- month cell (shared by grid + list) ----------

  Widget _monthCell(BuildContext context, AppLocalizations l10n,
      _CalMonth month, String currentKey) {
    final isCurrent = month.key == currentKey;
    final label = month.label();
    final hasIncome = month.totalUsd > 0 && month.entries.isNotEmpty;

    // One merged, labelled node per month cell — "July 2026, $310
    // expected, KO, ABBV" (round-3 a11y conventions).
    final semLabel = hasIncome
        ? l10n.calMonthSem(label, _money(month.totalUsd),
            month.entries.map((e) => e.symbol).join(', '))
        : l10n.calMonthSemEmpty(label);

    return MergeSemantics(
      child: Semantics(
        label: semLabel,
        excludeSemantics: true,
        container: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 104),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isCurrent
                  ? context.accentSoft(context.tealAccent)
                  : context.hairline,
              width: isCurrent ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isCurrent ? context.tealAccent : context.textSubtle,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                // Zero months render a muted em-dash, never disappear —
                // seeing the dry months is the point of the grid.
                hasIncome ? _money(month.totalUsd) : '—',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: hasIncome ? context.textPrimary : context.textFaint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (hasIncome) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: _chips(context, l10n, month),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- per-symbol chips ----------

  List<Widget> _chips(
      BuildContext context, AppLocalizations l10n, _CalMonth month) {
    final visible = month.entries.take(_maxChips).toList();
    final overflow = month.entries.skip(_maxChips).toList();
    return [
      for (final e in visible)
        _chip(
          context,
          label: '${e.symbol} · ${_money(e.amountUsd)}',
          tooltip: l10n.calEstExDate(e.dateLabel()),
          accent: true,
        ),
      if (overflow.isNotEmpty)
        _chip(
          context,
          label: l10n.calMoreChip(overflow.length),
          // The overflow chip's tooltip lists every hidden entry, one
          // per line, with its amount and estimated date.
          tooltip: overflow
              .map((e) =>
                  '${e.symbol} · ${_money(e.amountUsd)} · ${e.dateLabel()}')
              .join('\n'),
          accent: false,
        ),
    ];
  }

  /// Chip in the freq-chip styling family (teal 12% fill); the "+N more"
  /// overflow chip goes muted so it reads as a control, not a payer.
  Widget _chip(BuildContext context,
      {required String label, required String tooltip, required bool accent}) {
    final fg = accent ? context.tealAccent : context.textMuted;
    final bg =
        accent ? context.tealAccent.withValues(alpha: 0.12) : context.tint(0.06);
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: fg,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
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
