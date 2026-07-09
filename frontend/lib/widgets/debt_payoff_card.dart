import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/account_category.dart';
import '../utils/currency.dart';
import '../utils/debt_payoff.dart';
import '../utils/mask_aware_name.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

/// Rolls a monthly due-date [anchor] forward to its next occurrence on or after
/// [today]. The comparison is date-only, so a due date that lands on today
/// counts as due *today* rather than rolling to next month. The day-of-month is
/// clamped to the length of the target month, so a 31st anchor lands on the last
/// day of shorter months instead of overflowing into the next one. Pure and
/// top-level so the roll-forward logic is unit-testable without the widget.
DateTime rollDueForward(DateTime anchor, DateTime today) {
  var y = today.year;
  var m = today.month;
  final todayDate = DateTime(today.year, today.month, today.day);
  DateTime candidate() {
    final lastDay = DateTime(y, m + 1, 0).day; // day 0 of next month = last day
    return DateTime(y, m, anchor.day.clamp(1, lastDay));
  }

  var d = candidate();
  while (d.isBefore(todayDate)) {
    m++;
    if (m > 12) {
      m = 1;
      y++;
    }
    d = candidate();
  }
  return d;
}

/// Pure summary math over a list of debts, powering the summary strip above the
/// debt rows: total balance owed, the balance-weighted average APR, and the
/// monthly interest cost (Σ balance·apr/12 — how much interest the debts accrue
/// this month). Extracted as a top-level value type so the math is unit-testable
/// without pumping the widget.
class DebtSummary {
  /// Sum of all debt balances (USD-normalised, same units as [Debt.balance]).
  final double totalOwed;

  /// Balance-weighted average annual rate, as a fraction (e.g. 0.2299 = 22.99%).
  /// Zero when there is nothing owed.
  final double weightedApr;

  /// Monthly interest cost: Σ balance·apr/12.
  final double monthlyInterest;

  const DebtSummary({
    required this.totalOwed,
    required this.weightedApr,
    required this.monthlyInterest,
  });

  factory DebtSummary.from(List<Debt> debts) {
    var total = 0.0;
    var weighted = 0.0;
    var monthly = 0.0;
    for (final d in debts) {
      total += d.balance;
      weighted += d.balance * d.aprAnnual;
      monthly += d.balance * d.aprAnnual / 12;
    }
    return DebtSummary(
      totalOwed: total,
      weightedApr: total > 0 ? weighted / total : 0.0,
      monthlyInterest: monthly,
    );
  }
}

/// Debt-payoff simulator: compares the avalanche (highest-APR-first) and
/// snowball (smallest-balance-first) strategies for the user's credit/loan
/// balances at a chosen monthly payment, and recommends the one that pays the
/// least interest. APRs are entered per debt and persisted. Renders nothing
/// when there are no debts.
class DebtPayoffCard extends StatefulWidget {
  final List<dynamic> accounts;
  final ApiService apiService;
  final double conversionFactor;
  /// USD<->MXN spot rate, used to normalise native account balances to USD
  /// before the payoff simulation (which assumes a single currency).
  final double usdMxnRate;
  final NumberFormat currencyFormat;

  const DebtPayoffCard({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.conversionFactor,
    required this.usdMxnRate,
    required this.currencyFormat,
  });

  @override
  State<DebtPayoffCard> createState() => _DebtPayoffCardState();
}

class _DebtPayoffCardState extends State<DebtPayoffCard> {
  Map<String, double> _aprs = const {};
  // Per-account manual card terms (statement balance / min payment / due date),
  // keyed by account id. Value is a nested object; see Preferences.getCardTerms.
  Map<String, dynamic> _cardTerms = const {};
  double? _monthlyPayment; // null until initialized from the debts
  // Phone-only: the what-if simulator (slider + strategy tiles) collapses
  // behind a tap-to-expand header so the debt list stays the focus. In-memory.
  bool _simExpanded = false;

  @override
  void initState() {
    super.initState();
    _aprs = Preferences.getAccountAprs();
    _cardTerms = Preferences.getCardTerms();
    _hydrateAprs();
    _hydrateCardTerms();
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

  // Mirror of _hydrateAprs for the nested card_terms object: seed from
  // localStorage in initState, then refresh from the server settings store.
  Future<void> _hydrateCardTerms() async {
    try {
      final raw = await widget.apiService.getSetting('card_terms');
      if (mounted && raw is Map) {
        final next = Map<String, dynamic>.from(raw);
        setState(() => _cardTerms = next);
        Preferences.setCardTerms(next);
      }
    } catch (_) {
      // localStorage seed stands.
    }
  }

  // --- card_terms accessors (opt-in per account) -----------------------------

  Map<String, dynamic>? _termsFor(String id) {
    final t = _cardTerms[id];
    return t is Map ? Map<String, dynamic>.from(t) : null;
  }

  // The stored monthly due-date anchor for [id], or null when none entered.
  DateTime? _dueAnchor(String id) {
    final raw = _termsFor(id)?['due_date'];
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  // A numeric term (statement_balance / minimum_payment) in NATIVE currency.
  double? _termAmount(String id, String key) {
    final v = _termsFor(id)?[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  String _currencyFor(String id) {
    for (final raw in widget.accounts) {
      if (raw is Map && raw['id'].toString() == id) {
        return (raw['currency'] ?? 'USD').toString();
      }
    }
    return 'USD';
  }

  // Convert a native-currency term amount to USD, matching how _debts
  // normalises balances, so due-soon amounts line up with the debt rows.
  double _termToUsd(double native, String id) => convertCurrency(
        native,
        from: _currencyFor(id),
        to: 'USD',
        usdMxnRate: widget.usdMxnRate,
      );

  // Credit/loan accounts with a positive balance owed.
  List<Debt> get _debts {
    final out = <Debt>[];
    for (final raw in widget.accounts) {
      if (raw is! Map) continue;
      final cat = categorizeAccount(raw['account_type']?.toString());
      if (cat != AccountCategory.credit && cat != AccountCategory.loan) {
        continue;
      }
      // Normalise to USD: balances are native, but the simulation and _money
      // (which multiplies by conversionFactor) both assume USD. Without this a
      // MXN 50,000 card was treated as $50,000 USD (~17x inflated).
      final bal = convertCurrency(
        ((raw['current_balance'] as num?)?.toDouble() ?? 0).abs(),
        from: (raw['currency'] ?? 'USD').toString(),
        to: 'USD',
        usdMxnRate: widget.usdMxnRate,
      );
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

  // Credit-vs-loan split for the summary strip. Recomputed from the raw
  // accounts (the Debt model carries no category); mirrors _debts' filter +
  // USD-normalisation so the counts/amounts line up with the visible rows.
  ({int creditCount, double creditOwed, int loanCount, double loanOwed})
      get _split {
    var creditCount = 0;
    var loanCount = 0;
    var creditOwed = 0.0;
    var loanOwed = 0.0;
    for (final raw in widget.accounts) {
      if (raw is! Map) continue;
      final cat = categorizeAccount(raw['account_type']?.toString());
      if (cat != AccountCategory.credit && cat != AccountCategory.loan) {
        continue;
      }
      final bal = convertCurrency(
        ((raw['current_balance'] as num?)?.toDouble() ?? 0).abs(),
        from: (raw['currency'] ?? 'USD').toString(),
        to: 'USD',
        usdMxnRate: widget.usdMxnRate,
      );
      if (bal <= 0) continue;
      if (cat == AccountCategory.credit) {
        creditCount++;
        creditOwed += bal;
      } else {
        loanCount++;
        loanOwed += bal;
      }
    }
    return (
      creditCount: creditCount,
      creditOwed: creditOwed,
      loanCount: loanCount,
      loanOwed: loanOwed,
    );
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
            _dueSoonStrip(debts, l),
            _summaryStrip(debts, l),
            const SizedBox(height: 16),
            Divider(height: 1, color: context.hairline),
            const SizedBox(height: 12),
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

  // The debt headline: a compact 3-up metric row (total owed · weighted APR ·
  // monthly interest) plus a muted credit-vs-loan split. All client-derived
  // from the already-built debt list; no backend. Monthly interest is the
  // headline cost, tinted `warning` when the debts are bleeding interest.
  Widget _summaryStrip(List<Debt> debts, AppLocalizations l) {
    final s = DebtSummary.from(debts);
    final split = _split;
    final splitParts = <String>[];
    // gen-l10n orders these placeholder params alphabetically → (amount, count).
    if (split.creditCount > 0) {
      splitParts.add(
          l.dpSplitCredit(_money(split.creditOwed), '${split.creditCount}'));
    }
    if (split.loanCount > 0) {
      splitParts
          .add(l.dpSplitLoan(_money(split.loanOwed), '${split.loanCount}'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _metric(l.dpTotalOwed, _money(s.totalOwed))),
            Expanded(
              child: _metric(
                l.dpWeightedApr,
                formatPercent(context, s.weightedApr * 100, digits: 2),
              ),
            ),
            Expanded(
              child: _metric(
                l.dpMonthlyInterest,
                _money(s.monthlyInterest),
                valueColor: s.monthlyInterest > 0 ? context.warning : null,
              ),
            ),
          ],
        ),
        if (splitParts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            splitParts.join('      '),
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
        ],
      ],
    );
  }

  // One label-over-value metric cell in the summary strip. Label muted 11px
  // (matching credit_utilization_card's header), value bold with tabular
  // figures so the 3-up row aligns; scales down rather than overflowing.
  Widget _metric(String label, String value, {Color? valueColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: context.textSubtle,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: valueColor ?? context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _debtRow(Debt d) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: maskAwareNameText(
              d.name,
              TextStyle(
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
                    formatPercent(context, d.aprAnnual * 100, digits: 2),
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
          const SizedBox(width: 8),
          _termsChip(d),
        ],
      ),
    );
  }

  // Second per-row chip (teal, to read distinctly from the pink APR chip).
  // With a due date it shows the rolled-forward countdown ("Due in Nd" / "Due
  // today"); with no terms it's a neutral "＋ terms" affordance — either way it
  // opens the 3-field terms editor. Fully opt-in: no terms = no due-soon row.
  Widget _termsChip(Debt d) {
    final l = AppLocalizations.of(context);
    final accent = context.tealAccent;
    final anchor = _dueAnchor(d.id);
    final String label;
    final IconData icon;
    if (anchor != null) {
      final today = DateTime.now();
      final todayDate = DateTime(today.year, today.month, today.day);
      final due = rollDueForward(anchor, today);
      final days = due.difference(todayDate).inDays;
      label = days <= 0 ? l.dpDueToday : l.dpDueInDays(days);
      icon = Icons.event_available_rounded;
    } else {
      label = l.dpAddTerms;
      icon = Icons.add_rounded;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _editCardTerms(d),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // "Due soon": every debt with a due date, rolled forward to its next monthly
  // occurrence, sorted ascending, at most four rows. Renders nothing (and adds
  // no spacing) until at least one card has a due date, keeping the feature
  // invisible until opted into. Amounts convert native→USD via _money.
  Widget _dueSoonStrip(List<Debt> debts, AppLocalizations l) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final entries = <({Debt debt, DateTime due, int days})>[];
    for (final d in debts) {
      final anchor = _dueAnchor(d.id);
      if (anchor == null) continue;
      final due = rollDueForward(anchor, today);
      entries.add((
        debt: d,
        due: due,
        days: due.difference(todayDate).inDays,
      ));
    }
    if (entries.isEmpty) return const SizedBox.shrink();
    entries.sort((a, b) => a.due.compareTo(b.due));
    final df = DateFormat.MMMEd(Localizations.localeOf(context).toString());

    final rows = entries.take(4).map((e) {
      // Urgency colour on the countdown token only: today/overdue → negative,
      // within five days → amber warning, otherwise a subtle muted tone.
      final Color urgency = e.days <= 0
          ? context.negative
          : (e.days <= 5 ? context.warning : context.textSubtle);
      final daysLabel =
          e.days < 0 ? l.dpOverdue : (e.days == 0 ? l.dpDueToday : l.dpInDays(e.days));
      final min = _termAmount(e.debt.id, 'minimum_payment');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(
          TextSpan(
            style: TextStyle(
              fontSize: 12,
              color: context.textSubtle,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            children: [
              TextSpan(
                text: e.debt.name,
                style: TextStyle(
                  color: context.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(text: '  ·  ${l.dpDueOn(df.format(e.due))}  ·  '),
              TextSpan(
                text: daysLabel,
                style: TextStyle(color: urgency, fontWeight: FontWeight.w700),
              ),
              if (min != null && min > 0)
                TextSpan(
                  text: '  ·  '
                      '${l.dpMinAmount(_money(_termToUsd(min, e.debt.id)))}',
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.event_rounded, color: context.tealAccent, size: 16),
            const SizedBox(width: 6),
            Text(
              l.dpDueSoonTitle,
              style: TextStyle(
                fontSize: 11,
                color: context.textSubtle,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...rows,
        const SizedBox(height: 16),
      ],
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
    final pct = double.tryParse(controller.text);
    // dispose: local controller, else the dialog leaks it. Read .text first,
    // then dispose on every exit path below.
    controller.dispose();
    if (saved != true) return;
    if (pct == null || pct < 0) return;
    final next = Map<String, double>.from(_aprs);
    next[d.id] = pct / 100.0;
    setState(() => _aprs = next);
    Preferences.setAccountAprs(next);
    widget.apiService.putSetting('account_aprs', next).catchError((_) {});
  }

  // Per-card terms editor: three optional fields (statement balance, minimum
  // payment — both in the account's native currency — and a monthly due-date
  // anchor via showDatePicker). Modeled on _editApr, persisted to the nested
  // card_terms object. Clearing all three removes the card's entry entirely.
  Future<void> _editCardTerms(Debt d) async {
    final l = AppLocalizations.of(context);
    final stmtCtrl = TextEditingController(
      text: _termAmount(d.id, 'statement_balance')?.toString() ?? '',
    );
    final minCtrl = TextEditingController(
      text: _termAmount(d.id, 'minimum_payment')?.toString() ?? '',
    );
    var dueDate = _dueAnchor(d.id);
    final locale = Localizations.localeOf(context).toString();

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dctx, setLocal) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          title: Text(l.dpEditCardTerms(d.name)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: stmtCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: l.dpStatementBalance),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: minCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: l.dpMinPayment),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${l.dpDueDate}: '
                      '${dueDate != null ? DateFormat.yMMMd(locale).format(dueDate!) : l.dpDueDateNone}',
                      style:
                          TextStyle(color: context.textSubtle, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: dctx,
                        initialDate: dueDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setLocal(() => dueDate = picked);
                    },
                    child: Text(l.dpDueDate),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: Text(l.actionCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: Text(l.actionSave)),
          ],
        ),
      ),
    );
    final stmt = double.tryParse(stmtCtrl.text.trim());
    final minPay = double.tryParse(minCtrl.text.trim());
    // dispose: local controllers, else the dialog leaks them. Read .text first.
    stmtCtrl.dispose();
    minCtrl.dispose();
    if (saved != true) return;

    final entry = <String, dynamic>{};
    if (stmt != null && stmt > 0) entry['statement_balance'] = stmt;
    if (minPay != null && minPay > 0) entry['minimum_payment'] = minPay;
    if (dueDate != null) {
      entry['due_date'] = DateFormat('yyyy-MM-dd').format(dueDate!);
    }

    final next = Map<String, dynamic>.from(_cardTerms);
    if (entry.isEmpty) {
      next.remove(d.id);
    } else {
      next[d.id] = entry;
    }
    setState(() => _cardTerms = next);
    Preferences.setCardTerms(next);
    widget.apiService.putSetting('card_terms', next).catchError((_) {});
  }
}
