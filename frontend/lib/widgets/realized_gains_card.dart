import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';

/// Realized capital gains/losses from `/dashboard/realized-gains`.
///
/// Surfaces the per-sell P&L the FIFO engine crystallizes into `lot_disposals`
/// but the holdings view never shows. Renders nothing when the user has no
/// realized sells, so it stays out of the way for cash-only accounts.
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
  Map<String, dynamic>? _data;
  static const _maxRows = 8;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.apiService.getRealizedGains();
      if (mounted) setState(() => _data = data);
    } catch (_) {
      // swallow — the empty/collapsed render handles the failure case
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
    // Stay invisible until loaded, and skip entirely when there's nothing
    // realized — most cash/credit-only users never sell securities.
    if (_loading) return const SizedBox.shrink();
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    final disposals = (data['disposals'] as List<dynamic>?) ?? const [];
    if (disposals.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final summary = (data['summary'] as Map<String, dynamic>?) ?? const {};
    final ytd = (summary['ytd_realized_usd'] as num?)?.toDouble() ?? 0.0;
    final total = (summary['total_realized_usd'] as num?)?.toDouble() ?? 0.0;

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.trending_up_rounded,
                      color: context.tealAccent, size: 18),
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
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _summaryTile(l.rgThisYear, ytd)),
                  const SizedBox(width: 16),
                  Expanded(child: _summaryTile(l.rgAllTime, total)),
                ],
              ),
              const SizedBox(height: 8),
              Divider(height: 24, color: context.hairline),
              ...disposals
                  .take(_maxRows)
                  .map((d) => _disposalRow(d as Map<String, dynamic>)),
              if (disposals.length > _maxRows)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l.rgMoreCount(disposals.length - _maxRows),
                    style: TextStyle(color: context.textFaint, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryTile(String label, double usd) {
    return Container(
      padding: const EdgeInsets.all(16),
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
