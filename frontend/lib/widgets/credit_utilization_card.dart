import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';

class CreditUtilizationCard extends StatefulWidget {
  final List<dynamic> creditData;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const CreditUtilizationCard({
    super.key,
    required this.creditData,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<CreditUtilizationCard> createState() => _CreditUtilizationCardState();
}

class _CreditUtilizationCardState extends State<CreditUtilizationCard> {
  static const int _collapsedLimit = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Read the props through `widget.` (StatefulWidget body).
    final creditData = widget.creditData;
    // Nothing to show when the user has no tracked credit accounts — self-hide
    // rather than render a full empty-state card, matching every other optional
    // Overview widget (goal, emergency fund, assets bar). Avoids a dead card +
    // its gap on the space-constrained mobile dashboard.
    if (creditData.isEmpty) {
      return const SizedBox.shrink();
    }

    double limitOf(dynamic i) => ((i['credit_limit'] ?? 0.0) as num).toDouble();
    double balanceOf(dynamic i) => ((i['balance'] ?? 0.0) as num).toDouble();
    // Utilization is only meaningful for cards whose issuer reports a limit
    // (Plaid's balances.limit is null for some). Aggregate over those only, so
    // a limitless card doesn't drag the headline % to a misleading value.
    final withLimit = creditData.where((i) => limitOf(i) > 0).toList();
    final totalBalance =
        withLimit.fold<double>(0.0, (sum, i) => sum + balanceOf(i));
    final totalLimit = withLimit.fold<double>(0.0, (sum, i) => sum + limitOf(i));
    final hasLimits = totalLimit > 0;
    final totalUtilization =
        hasLimits ? (totalBalance / totalLimit) * 100 : 0.0;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l.cfCreditUtilizationHeader,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.textSubtle,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  hasLimits ? '${totalUtilization.toStringAsFixed(1)}%' : '—',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: !hasLimits
                        ? context.textSubtle
                        : totalUtilization > 30
                            ? context.warning
                            : context.positive,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // The overall bar only makes sense when at least one card reports a
            // limit; otherwise it'd be a permanently-empty 0% bar.
            if (hasLimits) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  value: (totalUtilization / 100).clamp(0.0, 1.0),
                  backgroundColor: context.hairline,
                  color: totalUtilization > 30
                      ? context.warning
                      : context.positive,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 24),
            ] else
              const SizedBox(height: 16),
            ..._buildCreditRows(),
          ],
        ),
      ),
    );
  }

  /// Sort by utilization (highest first) and cap at `_collapsedLimit`
  /// unless the user has expanded the list. Caps prevent a portfolio of
  /// 10+ credit cards from dominating the Overview tab.
  List<Widget> _buildCreditRows() {
    final l = AppLocalizations.of(context);
    final creditData = widget.creditData;
    final conversionFactor = widget.conversionFactor;
    final currencyFormat = widget.currencyFormat;

    final sorted = [...creditData]..sort((a, b) {
        double util(dynamic x) {
          final balance = ((x['balance'] ?? 0.0) as num).toDouble();
          final limit = ((x['credit_limit'] ?? 0.0) as num).toDouble();
          return limit > 0 ? balance / limit : 0.0;
        }
        return util(b).compareTo(util(a));
      });

    final visible = _expanded || sorted.length <= _collapsedLimit
        ? sorted
        : sorted.take(_collapsedLimit).toList();

    final rows = <Widget>[];
    for (final item in visible) {
      final balance = ((item['balance'] ?? 0.0) as num).toDouble();
      final limit = ((item['credit_limit'] ?? 0.0) as num).toDouble();
      final hasLimit = limit > 0;
      final util = hasLimit ? (balance / limit) * 100 : 0.0;
      final es = Localizations.localeOf(context).languageCode == 'es';
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['name'] ?? l.cfCreditAccountFallback,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        item['institution_name'] ?? '',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSubtle,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // With a known limit: "balance / limit". Without: just the
                // balance owed + a muted "no limit" note, instead of a
                // misleading "/ $0.00".
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      hasLimit
                          ? '${currencyFormat.format(balance * conversionFactor)} / ${currencyFormat.format(limit * conversionFactor)}'
                          : currencyFormat.format(balance * conversionFactor),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (!hasLimit)
                      Text(
                        es ? 'límite no disponible' : 'limit unavailable',
                        style: TextStyle(
                          fontSize: 10,
                          color: context.textFaint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (hasLimit) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (util / 100).clamp(0.0, 1.0),
                  backgroundColor: context.hairline,
                  color: util > 30
                      ? context.warning.withValues(alpha: 0.7)
                      : context.positive.withValues(alpha: 0.7),
                  minHeight: 4,
                ),
              ),
            ],
          ],
        ),
      ));
    }

    if (sorted.length > _collapsedLimit) {
      final hidden = sorted.length - _collapsedLimit;
      rows.add(Center(
        child: TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: Text(_expanded
              ? l.cfCreditShowFewer
              : l.cfCreditShowMore(hidden)),
          style: TextButton.styleFrom(foregroundColor: context.textMuted),
        ),
      ));
    }

    return rows;
  }
}
