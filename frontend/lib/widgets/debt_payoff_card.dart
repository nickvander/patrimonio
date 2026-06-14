import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/account_category.dart';
import '../utils/debt_payoff.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';

/// Debt-payoff simulator: compares the avalanche (highest-APR-first) and
/// snowball (smallest-balance-first) strategies for the user's credit/loan
/// balances at a chosen monthly payment, and recommends the one that pays the
/// least interest. APRs are entered per debt and persisted. Renders nothing
/// when there are no debts.
class DebtPayoffCard extends StatefulWidget {
  final List<dynamic> accounts;
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const DebtPayoffCard({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<DebtPayoffCard> createState() => _DebtPayoffCardState();
}

class _DebtPayoffCardState extends State<DebtPayoffCard> {
  Map<String, double> _aprs = const {};
  double? _monthlyPayment; // null until initialized from the debts
  // Phone-only: the what-if simulator (slider + strategy tiles) collapses
  // behind a tap-to-expand header so the debt list stays the focus. In-memory.
  bool _simExpanded = false;

  @override
  void initState() {
    super.initState();
    _aprs = Preferences.getAccountAprs();
    _hydrateAprs();
  }

  Future<void> _hydrateAprs() async {
    try {
      final raw = await widget.apiService.getSetting('account_aprs');
      if (mounted && raw is Map) {
        final next = <String, double>{};
        raw.forEach((k, v) {
          final d = v is num ? v.toDouble() : double.tryParse('$v');
          if (d != null && d > 0) next[k.toString()] = d;
        });
        setState(() => _aprs = next);
        Preferences.setAccountAprs(next);
      }
    } catch (_) {
      // localStorage seed stands.
    }
  }

  // Credit/loan accounts with a positive balance owed.
  List<Debt> get _debts {
    final out = <Debt>[];
    for (final raw in widget.accounts) {
      if (raw is! Map) continue;
      final cat = categorizeAccount(raw['account_type']?.toString());
      if (cat != AccountCategory.credit && cat != AccountCategory.loan) {
        continue;
      }
      final bal = ((raw['current_balance'] as num?)?.toDouble() ?? 0).abs();
      if (bal <= 0) continue;
      final id = raw['id'].toString();
      final defApr = cat == AccountCategory.credit ? 0.2299 : 0.0799;
      out.add(Debt(
        id: id,
        name: (raw['nickname']?.toString().trim().isNotEmpty ?? false)
            ? raw['nickname'].toString()
            : (raw['name'] ?? '').toString(),
        balance: bal,
        aprAnnual: _aprs[id] ?? defApr,
      ));
    }
    out.sort((a, b) => b.balance.compareTo(a.balance));
    return out;
  }

  double _minTotal(List<Debt> debts) => debts.fold(
      0.0, (s, d) => s + (d.balance * 0.02 > 25 ? d.balance * 0.02 : 25));

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  @override
  Widget build(BuildContext context) {
    final debts = _debts;
    if (debts.isEmpty) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);

    final minTotal = _minTotal(debts);
    // Default the budget to 1.5x minimums (rounded), once, when first shown.
    final budget = _monthlyPayment ??
        ((minTotal * 1.5) / 50).ceil() * 50.0;
    final sliderMax = (minTotal + 4000).ceilToDouble();
    final clampedBudget = budget.clamp(minTotal, sliderMax).toDouble();

    final avalanche =
        simulatePayoff(debts, clampedBudget, PayoffStrategy.avalanche);
    final snowball =
        simulatePayoff(debts, clampedBudget, PayoffStrategy.snowball);
    final feasible = avalanche.feasible && snowball.feasible;
    // Recommend the lower-interest plan (ties → avalanche).
    final avalancheWins =
        avalanche.totalInterest <= snowball.totalInterest;
    final savings = (snowball.totalInterest - avalanche.totalInterest).abs();

    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final pad = isPhone ? 16.0 : 24.0;

    // The strategy comparison: side-by-side on wide screens, stacked
    // vertically on phones (the two tiles crush at ~360px side by side).
    final avalancheTile = _strategyTile(
      l.dpAvalanche,
      l.dpAvalancheSub,
      avalanche,
      recommended: avalancheWins,
    );
    final snowballTile = _strategyTile(
      l.dpSnowball,
      l.dpSnowballSub,
      snowball,
      recommended: !avalancheWins,
    );
    final Widget strategyComparison = isPhone
        ? Column(
            children: [
              avalancheTile,
              const SizedBox(height: 12),
              snowballTile,
            ],
          )
        : Row(
            children: [
              Expanded(child: avalancheTile),
              const SizedBox(width: 12),
              Expanded(child: snowballTile),
            ],
          );

    // The what-if simulator: monthly-payment slider + strategy comparison.
    // Collapsible on phones, always inline on wide screens.
    final simulator = <Widget>[
      // Monthly payment slider.
      Row(
        children: [
          Expanded(
            child: Text(l.dpMonthlyPayment,
                style: TextStyle(color: context.textMuted, fontSize: 14)),
          ),
          Text(
            _money(clampedBudget),
            style: TextStyle(
              color: context.pinkAccent,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      Slider(
        value: clampedBudget,
        min: minTotal,
        max: sliderMax,
        activeColor: context.pinkAccent,
        inactiveColor: context.hairline,
        onChanged: (v) => setState(() => _monthlyPayment = v),
      ),
      const SizedBox(height: 8),
      if (!feasible)
        _infeasibleNote(l)
      else
        strategyComparison,
      if (feasible && savings > 1) ...[
        const SizedBox(height: 10),
        Center(
          child: Text(
            avalancheWins ? l.dpSaves(_money(savings)) : l.dpSaves(_money(0)),
            style: TextStyle(color: context.textFaint, fontSize: 11),
          ),
        ),
      ],
    ];

    // Collapsed-summary line: the recommended strategy + projected interest
    // saved (when meaningful), reusing the already-computed values.
    final recommendedName = avalancheWins ? l.dpAvalanche : l.dpSnowball;
    final summaryLine = (feasible && savings > 1 && avalancheWins)
        ? '$recommendedName · ${l.dpSaves(_money(savings))}'
        : recommendedName;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.trending_down_rounded,
                    color: context.pinkAccent, size: 18),
                const SizedBox(width: 8),
                Text(
                  l.dpTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...debts.map(_debtRow),
            const SizedBox(height: 8),
            Divider(height: 24, color: context.hairline),
            if (!isPhone)
              ...simulator
            else ...[
              // Tap-to-expand simulator header (phones only).
              InkWell(
                onTap: () => setState(() => _simExpanded = !_simExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.tune_rounded,
                          color: context.tealAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.dpSimulator,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary,
                              ),
                            ),
                            if (!_simExpanded) ...[
                              const SizedBox(height: 2),
                              Text(
                                summaryLine,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.textSubtle,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      Icon(
                        _simExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: context.textMuted,
                        size: 22,
                      ),
                    ],
                  ),
                ),
              ),
              if (_simExpanded) ...[
                const SizedBox(height: 8),
                ...simulator,
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _debtRow(Debt d) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              d.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: context.textPrimary, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _money(d.balance),
            style: TextStyle(
              color: context.textSubtle,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          // Tappable APR chip.
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _editApr(d),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: context.pinkAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${(d.aprAnnual * 100).toStringAsFixed(2)}%',
                    style: TextStyle(
                      color: context.pinkAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.edit, size: 11, color: context.pinkAccent),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _strategyTile(
    String title,
    String subtitle,
    PayoffResult r, {
    required bool recommended,
  }) {
    final color = recommended ? context.positive : context.textMuted;
    final l = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: recommended
            ? context.positive.withValues(alpha: 0.08)
            : context.tint(0.03),
        borderRadius: BorderRadius.circular(12),
        border: recommended
            ? Border.all(color: context.positive.withValues(alpha: 0.4))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
              if (recommended)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: context.positive.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(l.dpRecommended,
                      style: TextStyle(
                          color: context.positive,
                          fontSize: 9,
                          fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          Text(subtitle,
              style: TextStyle(color: context.textFaint, fontSize: 10)),
          const SizedBox(height: 8),
          Text(
            l.dpDebtFree(r.months),
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 2),
          Text(
            l.dpInterest(_money(r.totalInterest)),
            style: TextStyle(
              color: context.textSubtle,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infeasibleNote(AppLocalizations l) {
    final color = context.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(l.dpInfeasible,
                style: TextStyle(
                    color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<void> _editApr(Debt d) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(
      text: (d.aprAnnual * 100).toStringAsFixed(2),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.dpAprDialogTitle),
        content: TextField(
          controller: controller,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: l.dpEditApr(d.name),
            suffixText: '%',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.actionCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.actionSave)),
        ],
      ),
    );
    if (saved != true) return;
    final pct = double.tryParse(controller.text);
    if (pct == null || pct < 0) return;
    final next = Map<String, double>.from(_aprs);
    next[d.id] = pct / 100.0;
    setState(() => _aprs = next);
    Preferences.setAccountAprs(next);
    widget.apiService.putSetting('account_aprs', next).catchError((_) {});
  }
}
