import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';

/// "Investments vs S&P 500" — a dollar-weighted, contribution-timed comparison
/// over the user's tracked holding lots: if each lot's cost had instead bought
/// the S&P 500 on its acquisition date, what would it be worth now, vs what the
/// lots are actually worth.
///
/// We deliberately DON'T index net worth to 100 at its first snapshot: net
/// worth ramps up from ~0 as accounts are first synced, so that comparison
/// reports absurd returns (e.g. +3000%) by conflating contributions with
/// market gains. The contribution-weighted view below is the honest read.
/// Renders nothing until there are tracked lots to compare.
class BenchmarkCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const BenchmarkCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<BenchmarkCard> createState() => _BenchmarkCardState();
}

class _BenchmarkCardState extends State<BenchmarkCard> {
  bool _loading = true;
  Map<String, dynamic>? _comparison;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await widget.apiService.getBenchmarkComparison();
      if (mounted) {
        setState(() {
          _comparison = c;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final c = _comparison;
    if (c == null) return const SizedBox.shrink();
    final invested = (c['invested_usd'] as num?)?.toDouble() ?? 0;
    final lots = (c['lot_count'] as num?)?.toInt() ?? 0;
    if (invested <= 0 || lots <= 0) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final yourVal = (c['your_value_usd'] as num?)?.toDouble() ?? 0;
    final benchVal = (c['benchmark_value_usd'] as num?)?.toDouble() ?? 0;
    final youPct = (yourVal / invested - 1) * 100;
    final benchPct = (benchVal / invested - 1) * 100;
    final deltaPts = youPct - benchPct;
    final ahead = deltaPts >= 0;
    final maxVal = (yourVal > benchVal ? yourVal : benchVal).clamp(1, double.infinity);

    String pct(double p) => '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%';

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
                  Icon(Icons.insights_rounded,
                      color: context.tealAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.bmTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l.bmSubtitle,
                style: TextStyle(color: context.textFaint, fontSize: 11),
              ),
              const SizedBox(height: 18),
              // Two return tiles.
              Row(
                children: [
                  Expanded(child: _returnTile(l.bmContribYou, pct(youPct),
                      _money(yourVal), context.positive)),
                  const SizedBox(width: 12),
                  Expanded(child: _returnTile(l.bmContribIndex, pct(benchPct),
                      _money(benchVal), context.info)),
                ],
              ),
              const SizedBox(height: 16),
              // Value comparison bars (same invested base).
              _bar(l.bmContribYou, yourVal, maxVal.toDouble(), context.positive),
              const SizedBox(height: 8),
              _bar(l.bmContribIndex, benchVal, maxVal.toDouble(), context.info),
              const SizedBox(height: 14),
              Text(
                ahead
                    ? l.bmAheadPts(deltaPts.abs().toStringAsFixed(1))
                    : l.bmBehindPts(deltaPts.abs().toStringAsFixed(1)),
                style: TextStyle(
                  color: ahead ? context.positive : context.textMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l.bmContribNote(lots, _money(invested)),
                style: TextStyle(color: context.textFaint, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _returnTile(String label, String pct, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: context.textSubtle, fontSize: 11)),
          const SizedBox(height: 4),
          Text(pct,
              style: TextStyle(
                  color: color, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                color: context.textFaint,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }

  Widget _bar(String label, double value, double max, Color color) {
    final frac = (value / max).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(label,
              style: TextStyle(color: context.textMuted, fontSize: 11)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              children: [
                Container(height: 14, color: context.tileSurface),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(height: 14, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _money(value),
          style: TextStyle(
            color: context.textSubtle,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
