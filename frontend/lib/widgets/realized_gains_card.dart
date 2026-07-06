import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';
import 'skeleton.dart';

/// Realized capital gains/losses from `/dashboard/realized-gains`.
///
/// Surfaces the per-sell P&L the FIFO engine crystallizes into `lot_disposals`
/// but the holdings view never shows. While loading it holds its place with a
/// fixed-height skeleton; a failed fetch shows an inline error with retry and
/// no realized sells shows a one-line empty state (the card used to vanish
/// silently in all three cases).
class RealizedGainsCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const RealizedGainsCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<RealizedGainsCard> createState() => _RealizedGainsCardState();
}

class _RealizedGainsCardState extends State<RealizedGainsCard> {
  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic>? _data;
  static const _maxRows = 8;
  // Whether the disposal list shows everything or just the newest _maxRows.
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.apiService.getRealizedGains();
      if (mounted) {
        setState(() {
          _data = data;
          _failed = false;
        });
      }
    } catch (_) {
      // Surfaced as an inline error row with retry (was silently swallowed,
      // which made the whole card vanish on a failed fetch).
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _load();
  }

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  /// Signed money with a leading + on gains, for the P&L column.
  String _signedMoney(double usd) {
    final v = usd * widget.conversionFactor;
    final formatted = widget.currencyFormat.format(v.abs());
    if (v > 0) return '+$formatted';
    if (v < 0) return '-$formatted';
    return formatted;
  }

  Color _pnlColor(double v) =>
      v > 0 ? context.positive : (v < 0 ? context.negative : context.textMuted);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Fixed-height skeleton while loading so the ~700px card doesn't pop in
    // late and shove the layout once data lands.
    if (_loading) return _skeletonCard();
    if (_failed) return _errorCard(l);
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    final disposals = (data['disposals'] as List<dynamic>?) ?? const [];
    if (disposals.isEmpty) return _emptyCard(l);

    final summary = (data['summary'] as Map<String, dynamic>?) ?? const {};
    final ytd = (summary['ytd_realized_usd'] as num?)?.toDouble() ?? 0.0;
    final total = (summary['total_realized_usd'] as num?)?.toDouble() ?? 0.0;
    // The YTD tile names the year it covers (the backend computes
    // ytd_realized_usd over the current calendar year).
    final thisYear = DateTime.now().year.toString();

    final visible =
        _expanded ? disposals : disposals.take(_maxRows).toList();

    return _cardShell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(l),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _summaryTile(l.rgYearTile(thisYear), ytd)),
              const SizedBox(width: 12),
              Expanded(child: _summaryTile(l.rgAllTime, total)),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 24, color: context.hairline),
          ...visible.map((d) => _disposalRow(d as Map<String, dynamic>)),
          if (disposals.length > _maxRows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 6, horizontal: 4),
                  child: Text(
                    _expanded
                        ? l.rgShowFewer
                        : l.rgShowAll(disposals.length),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.tealAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Shared Card chrome so the skeleton/error/empty states keep the exact
  /// footprint and styling of the loaded card.
  Widget _cardShell(Widget child) {
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(padding: EdgeInsets.all(pad), child: child),
    );
  }

  Widget _titleRow(AppLocalizations l) {
    return Row(
      children: [
        Icon(Icons.trending_up_rounded, color: context.tealAccent, size: 18),
        const SizedBox(width: 8),
        Text(
          l.rgTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: context.textPrimary,
          ),
        ),
      ],
    );
  }

  /// Layout-true placeholder: title line, the two summary tiles, and a few
  /// disposal-row lines, all at their real heights.
  Widget _skeletonCard() {
    return _cardShell(
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 150, height: 18),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SkeletonBox(
                  height: 68,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: SkeletonBox(
                  height: 68,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
            ],
          ),
          SizedBox(height: 32),
          SkeletonBox(height: 14),
          SizedBox(height: 18),
          SkeletonBox(height: 14),
          SizedBox(height: 18),
          SkeletonBox(height: 14),
        ],
      ),
    );
  }

  Widget _errorCard(AppLocalizations l) {
    return _cardShell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(l),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: context.negative),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.rgLoadError,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: _retry,
                child: Text(l.rgRetry),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(AppLocalizations l) {
    return _cardShell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(l),
          const SizedBox(height: 12),
          Text(
            l.rgEmpty,
            style: TextStyle(color: context.textFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile(String label, double usd) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.tint(0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: context.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            _signedMoney(usd),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _pnlColor(usd),
            ),
          ),
        ],
      ),
    );
  }

  Widget _disposalRow(Map<String, dynamic> d) {
    final l = AppLocalizations.of(context);
    final symbol = d['symbol']?.toString() ?? '';
    final name = d['name']?.toString() ?? '';
    final sellDate = d['sell_date']?.toString() ?? '';
    final pnl = (d['realized_pnl_usd'] as num?)?.toDouble() ?? 0.0;
    final proceeds = (d['proceeds_usd'] as num?)?.toDouble() ?? 0.0;
    final longTerm = d['long_term']; // bool or null

    final parsed = DateTime.tryParse(sellDate);
    final dateLabel =
        parsed == null ? sellDate : DateFormat.yMMMd().format(parsed);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        symbol.isNotEmpty ? symbol : name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (longTerm is bool) ...[
                      const SizedBox(width: 8),
                      _termChip(longTerm ? l.rgLongTerm : l.rgShortTerm,
                          longTerm),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$dateLabel · ${l.rgProceeds} ${_money(proceeds)}',
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            _signedMoney(pnl),
            style: TextStyle(
              color: _pnlColor(pnl),
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _termChip(String label, bool longTerm) {
    final color = longTerm ? context.info : context.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}
