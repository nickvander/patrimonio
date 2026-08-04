import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/typography.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// "How many months of expenses could your liquid cash cover?" — reads
/// `/dashboard/emergency-fund` (cash / trailing monthly spend, both USD).
///
/// Status ladder: <3 mo = keep building (amber), 3–<6 = on track (info),
/// >=6 = fully funded (positive). The gauge runs 0→6 months so "healthy" is
/// a reachable full bar with a tick at the 3-month mark.
class EmergencyFundCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const EmergencyFundCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<EmergencyFundCard> createState() => _EmergencyFundCardState();
}

class _EmergencyFundCardState extends State<EmergencyFundCard> {
  bool _loading = true;
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.apiService.getEmergencyFund();
      if (mounted) setState(() => _data = d);
    } catch (_) {
      // collapsed render handles failure
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _money(double usd) =>
      widget.currencyFormat.displayMoney(usd * widget.conversionFactor);

  @override
  Widget build(BuildContext context) {
    // Stay invisible until loaded; the dashboard skeleton covers boot.
    if (_loading || _data == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final cash = (_data!['liquid_cash_usd'] as num?)?.toDouble() ?? 0.0;
    final spend = (_data!['monthly_spend_usd'] as num?)?.toDouble() ?? 0.0;
    final runway = (_data!['months_covered'] as num?)?.toDouble() ?? 0.0;
    final hasSpend = spend > 0;

    final (Color accent, String statusLabel) = !hasSpend
        ? (context.info, '')
        : runway >= 6
        ? (context.positive, l.efStatusHealthy)
        : runway >= 3
        ? (context.info, l.efStatusOnTrack)
        : (context.warning, l.efStatusBuilding);

    // Card padding off the card's OWN LayoutBuilder constraint, never
    // the window (skill §4/§5): the card is narrower than the screen on
    // every layout that pads or column-clamps its tab.
    return LayoutBuilder(
      builder: (_, outer) {
        final pad = outer.maxWidth < 720 ? 16.0 : 24.0;
        return Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_outlined, color: accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.efTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                    if (hasSpend) _statusPill(statusLabel, accent),
                  ],
                ),
                const SizedBox(height: 16),
                if (!hasSpend)
                  _noSpendBody(l, cash)
                else ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        runway.toStringAsFixed(1),
                        style: brandDisplayStyle(fontSize: 34, color: accent),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l.efMonthsUnit,
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _gauge(runway, accent),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l.efCashLabel(_money(cash)),
                        style: TextStyle(
                          color: context.textSubtle,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        l.efSpendLabel(_money(spend)),
                        style: TextStyle(
                          color: context.textFaint,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statusPill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );

  // 0→6 month gauge with a hairline tick at the 3-month mark.
  Widget _gauge(double runway, Color accent) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (runway / 6).clamp(0.0, 1.0),
                backgroundColor: context.tileSurface,
                color: accent,
                minHeight: 10,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.5, // 3-month mark on a 6-month scale
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 1.5,
                    height: 10,
                    color: context.hairline,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l.efScale0,
              style: TextStyle(color: context.textFaint, fontSize: 10),
            ),
            Text(
              l.efScale3,
              style: TextStyle(color: context.textFaint, fontSize: 10),
            ),
            Text(
              l.efScale6,
              style: TextStyle(color: context.textFaint, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  Widget _noSpendBody(AppLocalizations l, double cash) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.efNoSpendTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: context.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          cash > 0 ? l.efNoSpendBody : l.efNoCashHint,
          style: TextStyle(color: context.textMuted, fontSize: 13),
        ),
        if (cash > 0) ...[
          const SizedBox(height: 10),
          Text(
            l.efCashLabel(_money(cash)),
            style: TextStyle(
              color: context.textSubtle,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
