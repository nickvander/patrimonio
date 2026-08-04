import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/buttons.dart';
import '../utils/currency.dart' show MoneyDisplayFormat, moneyFormat;
import '../utils/lending_summary.dart';
import '../utils/loan_dates.dart';
import '../utils/theme_colors.dart';
import 'add_loan_dialog.dart';
import 'interest_income_sheet.dart';
import 'loan_detail_sheet.dart';

/// Personal lending tab — only mounted when the user enables the
/// module (app_settings 'lending_enabled'). Lists money the user has
/// lent, with auto-suggested reconciliation against real bank
/// transactions.
///
/// Self-contained: fetches its own loans + people + suggestions so the
/// dashboard doesn't have to thread loan state through. Calls
/// onChanged after any mutation so the dashboard can silently refresh
/// the cash-flow view (loan-linked transactions are excluded there).
/// Open the Add-loan dialog pre-filled from a transaction (the
/// "Create loan from this transaction" flow in the transactions tab).
/// [disbursementTxId] links the loan to that funding transaction after
/// creation; a 409 conflict rolls the loan back. Returns true when a loan
/// was created so the caller can refresh. Kept as a small public
/// entrypoint so cross-widget callers don't need to import the dialog widget.
Future<bool?> showCreateLoanFromTransactionDialog(
  BuildContext context, {
  required ApiService apiService,
  required List<dynamic> people,
  required String defaultCurrency,
  required double principal,
  required String currency,
  required DateTime originationDate,
  required String borrowerName,
  required String disbursementTxId,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => AddLoanDialog(
      apiService: apiService,
      people: people,
      defaultCurrency: defaultCurrency,
      initialPrincipal: principal,
      initialCurrency: currency,
      initialOriginationDate: originationDate,
      initialBorrowerName: borrowerName,
      disbursementTxId: disbursementTxId,
    ),
  );
}

class LendingTab extends StatefulWidget {
  final ApiService apiService;
  final String targetCurrency;

  /// USD→MXN spot rate, used to convert each loan from its native
  /// currency into [targetCurrency] for the summary totals. Defaults to
  /// 1.0 (no conversion) when the rate hasn't loaded.
  final double usdMxnRate;
  final VoidCallback? onChanged;

  /// Jump to a transaction in the Transactions tab (id + a search seed like
  /// the merchant/description). Lets a linked loan payment open its bank tx.
  final void Function(String txId, String description)? onOpenTransaction;

  const LendingTab({
    super.key,
    required this.apiService,
    required this.targetCurrency,
    this.usdMxnRate = 1.0,
    this.onChanged,
    this.onOpenTransaction,
  });

  @override
  State<LendingTab> createState() => _LendingTabState();
}

class _LendingTabState extends State<LendingTab> {
  List<dynamic> _loans = [];
  List<dynamic> _people = [];
  Map<String, dynamic> _summary = {};
  List<dynamic> _reminders = [];
  bool _loading = true;
  // Localized at build time (a State may not have a usable context in the
  // load catch), so only the *fact* of the failure is stored here.
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final results = await Future.wait([
        widget.apiService.getLoans(),
        widget.apiService.getLoanPeople(),
        widget.apiService.getLoansSummary(),
        // Aging/due section. Non-fatal: a failure here just hides the
        // section, it shouldn't blank out the whole tab.
        widget.apiService
            .getLoanReminders(forceRefresh: true)
            .catchError((_) => <dynamic>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _loans = results[0] as List<dynamic>;
        _people = results[1] as List<dynamic>;
        _summary = results[2] as Map<String, dynamic>;
        _reminders = results[3] as List<dynamic>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    }
  }

  String _money(num v, String currency) {
    // Anything whose magnitude rounds below half a cent is zero for display.
    // Without this, a negative zero (-0.0) or sub-cent residue formats as an
    // ugly "-$0.00" — e.g. the "Interest earned" stat with no payments yet.
    // Summary tiles and list rows are display surfaces, so cents drop at the
    // whole-money threshold ("$16,000" rather than "$16,000.00").
    return moneyFormat(currency).displayMoney(v.abs() < 0.005 ? 0 : v);
  }

  /// "≈ $1,729.18 USD" — the [amount] (in [fromCurrency]) converted to the
  /// active display currency at the spot rate. Returns null when no
  /// conversion is needed (same currency) or the rate isn't loaded, so the
  /// caller can omit the line entirely.
  String? _convertedLine(num amount, String fromCurrency) {
    final target = widget.targetCurrency;
    if (fromCurrency == target || widget.usdMxnRate <= 0) return null;
    final converted = convertCurrency(
      amount.toDouble(),
      fromCurrency,
      target,
      widget.usdMxnRate,
    );
    return '≈ ${_money(converted, target)} $target';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppLocalizations.of(context).lendLoadError,
              style: TextStyle(color: context.textMuted),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _load,
              child: Text(AppLocalizations.of(context).lendRetry),
            ),
          ],
        ),
      );
    }

    // Thumb-zone creation on touch-width layouts: the header drops its
    // labelled "Add loan" button (it overflowed at 390px) and the affordance
    // moves to a FAB pinned bottom-right. The list keeps 88dp of clearance so
    // the last loan card is never hidden under the FAB.
    //
    // Measured on the tab's OWN `LayoutBuilder` constraint, never
    // `MediaQuery` (skill §4/§5): the tab renders inside the dashboard's tab
    // container, whose padding and 1600px clamp put its real width below the
    // window's. The flag is computed ONCE here and threaded into
    // [_buildHeader] because the two must agree — the header renders the
    // labelled button exactly when this method does not render the FAB, so
    // two independent reads could show both affordances or neither.
    return LayoutBuilder(
      builder: (context, outer) {
        // Touch layout: the header's labelled "Add loan" button and the
        // interest-income button collapse (the former into a bottom-right
        // FAB, the latter into an icon), the four summary stats lay out 2-up
        // instead of as a Wrap, and cards use 16px of padding instead of 24.
        final phone = outer.maxWidth < kCompactCardBelow;
        final list = RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: EdgeInsets.only(bottom: phone ? 96 : 32),
            children: [
              _buildHeader(phone),
              if (_buildAgingSection() case final w?) ...[
                const SizedBox(height: 16),
                w,
              ],
              const SizedBox(height: 16),
              if (_loans.isEmpty)
                _buildEmptyState()
              else
                ..._loans.map(
                  (l) => _buildLoanCard(l as Map<String, dynamic>, phone),
                ),
            ],
          ),
        );
        if (!phone) return list;
        return Stack(
          children: [
            list,
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton(
                onPressed: _openAddLoanDialog,
                tooltip: AppLocalizations.of(context).lendingAddLoan,
                child: const Icon(Icons.add),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Currency to denominate the summary stats in. When every loan shares
  /// one currency we show that native currency (no FX conversion) so a
  /// single MXN 30,000 loan reads "MXN 30,000", not its USD equivalent.
  /// Only a genuinely mixed portfolio falls back to the display currency.
  String _summaryCurrency() {
    if (_loans.isEmpty) return widget.targetCurrency;
    final first = _loans.first;
    if (first is Map) {
      return (first['currency'] ?? widget.targetCurrency).toString();
    }
    return widget.targetCurrency;
  }

  /// [phone] is the tab's own touch-width flag, computed once in [build] from
  /// the tab's `LayoutBuilder` constraint and passed down so the header's
  /// labelled "Add loan" button and build()'s FAB can never both appear (or
  /// both vanish).
  Widget _buildHeader(bool phone) {
    // Single-currency portfolios show their native currency untouched;
    // only a genuinely mixed (USD + MXN) portfolio is converted to the
    // display currency at the spot rate (with the caveat note below).
    // When summaryCur equals a loan's own currency, sumLoansConverted's
    // convertCurrency hits its from==to early-return and leaves the
    // amount unchanged — so the header matches the per-loan cards.
    final mixed = loansAreMixedCurrency(_loans);
    final summaryCur = mixed ? widget.targetCurrency : _summaryCurrency();
    final totalLent = sumLoansConverted(
      _loans,
      'principal',
      summaryCur,
      widget.usdMxnRate,
    );
    // Total still owed across loans (principal + unpaid interest).
    final totalOut = sumLoansConverted(
      _loans,
      'total_owed',
      summaryCur,
      widget.usdMxnRate,
    );
    final interestEarned = sumLoansConverted(
      _loans,
      'interest_earned',
      summaryCur,
      widget.usdMxnRate,
    );
    final active = (_summary['active_count'] as num?)?.toInt() ?? 0;
    final pad = phone ? 16.0 : 24.0;
    final outstandingTile = _stat(
      AppLocalizations.of(context).lendingOutstanding,
      _money(totalOut, summaryCur),
      context.warning,
    );
    final totalLentTile = _stat(
      AppLocalizations.of(context).lendingTotalLent,
      _money(totalLent, summaryCur),
      context.textPrimary,
    );
    final activeTile = _stat(
      AppLocalizations.of(context).lendingActive,
      '$active',
      context.tealAccent,
    );
    // Interest income — the headline of this feature.
    final interestTile = _stat(
      AppLocalizations.of(context).lendingInterestEarned,
      _money(interestEarned, summaryCur),
      context.positive,
    );
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.monetization_on, color: context.tealAccent),
                const SizedBox(width: 8),
                // A7 (round 3, a11y): card header landmark. container:
                // forces the boundary so the flag can't absorb the card.
                // Expanded + ellipsis: the title yields to the action
                // cluster instead of RenderFlex-overflowing at narrow
                // widths (it did at 390px once interest was earned), but
                // takes ALL the leftover width so it only ellipsizes when
                // there genuinely isn't room. It was `Flexible` followed by
                // a `Spacer()`: both default to flex 1, so the free space
                // was split 50/50 and "Money I've lent" truncated to
                // "Money I'…" at 390px with ~150px of that row still empty.
                // Expanded IS the gap-filler, so the Spacer is gone.
                Expanded(
                  child: Semantics(
                    container: true,
                    header: true,
                    child: Text(
                      AppLocalizations.of(context).lendingTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                ),
                // Drill into the full cash-basis interest-income report
                // (per-month series, per-loan + per-currency totals,
                // §7872 below-market flag). Only meaningful once interest
                // has actually been received. On phones the labelled
                // button shrinks to a 48dp icon so the header row fits.
                if (interestEarned > 0)
                  phone
                      ? IconButton(
                          icon: const Icon(Icons.insights_outlined),
                          tooltip: AppLocalizations.of(
                            context,
                          ).lendingInterestIncomeTitle,
                          onPressed: _openInterestIncome,
                        )
                      : TextButton.icon(
                          onPressed: _openInterestIncome,
                          icon: const Icon(Icons.insights_outlined, size: 18),
                          label: Text(
                            AppLocalizations.of(
                              context,
                            ).lendingInterestIncomeTitle,
                          ),
                        ),
                // Export the loan-interest CSV (cash-basis interest
                // income — hand to an accountant at tax time).
                if (interestEarned > 0)
                  PopupMenuButton<String>(
                    tooltip: AppLocalizations.of(
                      context,
                    ).lendExportInterestTooltip,
                    icon: const Icon(Icons.download_outlined),
                    onSelected: (which) {
                      final url = which == 'summary'
                          ? widget.apiService.interestSummaryCsvUrl()
                          : widget.apiService.interestIncomeCsvUrl();
                      launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'detail',
                        child: Text(
                          AppLocalizations.of(context).lendExportPaymentsCsv,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'summary',
                        child: Text(
                          AppLocalizations.of(context).lendExportYearEndCsv,
                        ),
                      ),
                    ],
                  ),
                // Phones get the thumb-zone FAB instead (see build()).
                if (!phone)
                  FilledButton.icon(
                    onPressed: _openAddLoanDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(AppLocalizations.of(context).lendingAddLoan),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // Only a genuinely mixed portfolio is converted — explain it.
            if (mixed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  AppLocalizations.of(
                    context,
                  ).lendTotalsConvertedNote(summaryCur),
                  style: TextStyle(fontSize: 11, color: context.textSubtle),
                ),
              ),
            if (phone)
              // On phones, lay the 4 stats out as a 2-up grid (two rows of
              // two) like Home's mobile stat tiles, rather than a wide Wrap.
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: outstandingTile),
                      const SizedBox(width: 16),
                      Expanded(child: totalLentTile),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: activeTile),
                      const SizedBox(width: 16),
                      Expanded(child: interestTile),
                    ],
                  ),
                ],
              )
            else
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  outstandingTile,
                  totalLentTile,
                  activeTile,
                  interestTile,
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    // A7 (round 3, a11y): label + value announce as one node.
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Loan aging report: upcoming + overdue installments from
  /// getLoanReminders, grouped into urgency bands (most-overdue first).
  /// Returns null — hiding the whole section — when nothing is due.
  Widget? _buildAgingSection() {
    if (_reminders.isEmpty) return null;
    final l10n = AppLocalizations.of(context);

    // Band an item by how overdue / soon-due it is. Lower order sorts
    // first (oldest-overdue at the top).
    ({int order, String label, Color color}) bandOf(Map<String, dynamic> r) {
      final overdue = (r['days_overdue'] as num?)?.toInt() ?? 0;
      final until = (r['days_until'] as num?)?.toInt() ?? 0;
      if (overdue >= 30) {
        return (
          order: 0,
          label: l10n.lendingAgingOverdue30,
          color: context.negative,
        );
      }
      if (overdue >= 7) {
        return (
          order: 1,
          label: l10n.lendingAgingOverdue7,
          color: context.negative,
        );
      }
      if (overdue >= 1) {
        return (
          order: 2,
          label: l10n.lendingAgingOverdue1,
          color: context.warning,
        );
      }
      if (until <= 0) {
        return (
          order: 3,
          label: l10n.lendingAgingDueToday,
          color: context.warning,
        );
      }
      return (
        order: 4,
        label: l10n.lendingAgingDueSoon,
        color: context.tealAccent,
      );
    }

    // Sort: oldest-overdue first, then soonest-due. Within a band, the
    // most-overdue / soonest-due item leads.
    final items =
        _reminders
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList()
          ..sort((a, b) {
            final ba = bandOf(a), bb = bandOf(b);
            if (ba.order != bb.order) return ba.order.compareTo(bb.order);
            final oa = (a['days_overdue'] as num?)?.toInt() ?? 0;
            final ob = (b['days_overdue'] as num?)?.toInt() ?? 0;
            if (oa != ob) return ob.compareTo(oa); // more overdue first
            final ua = (a['days_until'] as num?)?.toInt() ?? 0;
            final ub = (b['days_until'] as num?)?.toInt() ?? 0;
            return ua.compareTo(ub); // sooner-due first
          });
    if (items.isEmpty) return null;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.event_busy, size: 18, color: context.warning),
                  const SizedBox(width: 8),
                  Text(
                    l10n.lendingAgingTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            ...items.map((r) {
              final band = bandOf(r);
              return _agingRow(r, band.label, band.color);
            }),
          ],
        ),
      ),
    );
  }

  Widget _agingRow(Map<String, dynamic> r, String bandLabel, Color color) {
    final l10n = AppLocalizations.of(context);
    final name = (r['borrower_name'] ?? '').toString();
    final currency = (r['currency'] ?? widget.targetCurrency).toString();
    final amount = (r['amount'] as num?)?.toDouble() ?? 0;
    final overdue = (r['days_overdue'] as num?)?.toInt() ?? 0;
    final until = (r['days_until'] as num?)?.toInt() ?? 0;
    final timing = overdue > 0
        ? '${l10n.lendingAgingDaysOverdue(overdue)} · $bandLabel'
        : until <= 0
        ? bandLabel
        : '${l10n.lendingAgingDaysUntil(until)} · $bandLabel';
    // A7 (round 3, a11y): the aging row is one tappable sentence —
    // "Ana, 12 days overdue · Overdue, $500.00" — instead of a label-less
    // InkWell plus loose text fragments.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () => _openLoanForReminder(r),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        timing,
                        style: TextStyle(fontSize: 11, color: color),
                      ),
                    ],
                  ),
                ),
                Text(
                  _money(amount, currency),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Open the detail sheet for the loan behind an aging row. Looks the
  /// loan up by id in the already-loaded list; no-ops if it's missing
  /// (e.g. an archived loan that no longer appears in the tab).
  void _openLoanForReminder(Map<String, dynamic> r) {
    final loanId = r['loan_id']?.toString();
    if (loanId == null) return;
    final loan = _loans.whereType<Map>().firstWhere(
      (l) => l['id']?.toString() == loanId,
      orElse: () => const {},
    );
    if (loan.isEmpty) return;
    _openLoanDetail(loan.cast<String, dynamic>());
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.monetization_on, size: 56, color: context.textFaint),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.of(context).lendingNoLoans,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppLocalizations.of(context).lendingEmptySubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.textSubtle),
          ),
        ],
      ),
    );
  }

  /// [phone] is the tab's touch-width flag from [build] — the loan card is a
  /// full-width row of the tab's list, so the tab's constraint IS this card's.
  Widget _buildLoanCard(Map<String, dynamic> loan, bool phone) {
    final currency = (loan['currency'] ?? 'USD').toString();
    // "Outstanding" here means the TOTAL still owed (principal + unpaid
    // interest) so the card matches the loan detail + agreement — a
    // 14k-principal + 2k-interest loan reads "16,000". Falls back to the
    // principal-based outstanding for older payloads.
    final outstanding =
        (loan['total_owed'] as num?)?.toDouble() ??
        (loan['outstanding'] as num?)?.toDouble() ??
        0;
    final principal = (loan['principal'] as num?)?.toDouble() ?? 0;
    final repaid = (loan['total_repaid'] as num?)?.toDouble() ?? 0;
    final status = (loan['status'] ?? 'active').toString();
    // Progress = (total to repay − still owed) / total to repay, so the bar
    // tracks payoff of the full amount and stays consistent with the figure
    // shown.
    final totalScheduled = (loan['total_scheduled'] as num?)?.toDouble() ?? 0;
    final totalToPay = totalScheduled > 0 ? totalScheduled : principal;
    final pct = totalToPay > 0
        ? ((totalToPay - outstanding) / totalToPay).clamp(0.0, 1.0)
        : 0.0;
    final linked = loan['disbursement_tx_id'] != null;
    // Unpaid scheduled interest baked into the "Outstanding" figure
    // (total_owed − principal-only outstanding) — see the footnote below.
    final interestIncluded = interestIncludedInOutstanding(
      loan['total_owed'] as num?,
      loan['outstanding'] as num?,
    );
    final pad = phone ? 16.0 : 24.0;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(top: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.hairline),
      ),
      // A7 (round 3, a11y): the whole loan card is one tappable sentence
      // (borrower, status, lent meta, repaid/outstanding merge in) instead
      // of a label-less InkWell over a dozen text fragments.
      child: MergeSemantics(
        child: Semantics(
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openLoanDetail(loan),
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          (loan['borrower_name'] ??
                                  AppLocalizations.of(
                                    context,
                                  ).lendUnknownBorrower)
                              .toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                          ),
                        ),
                      ),
                      if (_dueStatusPill(loan) case final p?) ...[
                        p,
                        const SizedBox(width: 6),
                      ],
                      _statusPill(status),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    // gen-l10n orders placeholders alphabetically (amount, date) —
                    // same as the template order here. The origination date is
                    // rendered locale-aware, not as the raw ISO payload string.
                    '${AppLocalizations.of(context).lendLentMeta(_money(principal, currency), formatIsoDateMedium((loan['origination_date'] ?? '').toString()))}'
                    '${linked ? '' : ' · ${AppLocalizations.of(context).lendDisbursementNotLinkedOptional}'}',
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                  ),
                  // When the loan is in a different currency than the display
                  // toggle, show the converted equivalent at the spot rate —
                  // same idea as the Transactions tab's "≈" line.
                  if (_convertedLine(principal, currency) != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _convertedLine(principal, currency)!,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textFaint,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 6,
                      backgroundColor: context.tint(0.08),
                      valueColor: AlwaysStoppedAnimation(context.positive),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${AppLocalizations.of(context).lendingRepaid} ${_money(repaid, currency)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                        ),
                      ),
                      Text(
                        '${AppLocalizations.of(context).lendingOutstanding} ${_money(outstanding, currency)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: outstanding > 0
                              ? context.warning
                              : context.positive,
                        ),
                      ),
                    ],
                  ),
                  // "Outstanding" is the TOTAL owed; when unpaid scheduled
                  // interest is part of that figure, say so — otherwise the
                  // number silently reads as principal.
                  if (interestIncluded > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          AppLocalizations.of(
                            context,
                          ).lendingOutstandingInclInterest(
                            _money(interestIncluded, currency),
                          ),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: context.textFaint,
                          ),
                        ),
                      ),
                    ),
                  // Interest on this loan: realized income (cash basis) and,
                  // beside it, the informational "owed so far" accrual that
                  // hasn't been paid yet. Accrued is already zeroed server-side
                  // for terminal statuses, but gate here too so a paid_off loan
                  // never shows an "owed" amount.
                  if (_interestLine(loan, currency, status) case final w?) ...[
                    const SizedBox(height: 4),
                    w,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The card's interest line: realized interest_earned (positive/income)
  /// and, when there's unpaid simple interest accrued to date, an
  /// "interest owed so far" figure beside it (warning-toned, like the
  /// detail sheet). Returns null when neither figure is meaningful.
  Widget? _interestLine(
    Map<String, dynamic> loan,
    String currency,
    String status,
  ) {
    final earned = (loan['interest_earned'] as num?)?.toDouble() ?? 0;
    // Mirror the detail sheet: never surface an "owed" amount on a
    // terminal loan, even if a stale accrual slipped through.
    final terminal =
        status == 'paid_off' ||
        status == 'cancelled' ||
        status == 'written_off';
    final accrued = terminal
        ? 0.0
        : (loan['interest_accrued'] as num?)?.toDouble() ?? 0;
    if (earned <= 0 && accrued <= 0) return null;

    final l10n = AppLocalizations.of(context);
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        children: [
          if (earned > 0)
            TextSpan(
              text: '${l10n.lendingInterestEarned} ${_money(earned, currency)}',
              style: TextStyle(color: context.positive),
            ),
          if (earned > 0 && accrued > 0)
            TextSpan(
              text: ' · ',
              style: TextStyle(color: context.textFaint),
            ),
          if (accrued > 0)
            TextSpan(
              text:
                  '${l10n.lendingInterestOwedSoFar} ${_money(accrued, currency)}',
              style: TextStyle(color: context.warning),
            ),
        ],
      ),
    );
  }

  Widget _statusPill(String status) {
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (status) {
      'paid_off' => (l10n.lendStatusPaidOff, context.positive),
      'written_off' => (l10n.lendStatusWrittenOff, context.negative),
      'defaulted' => (l10n.lendStatusDefaulted, context.negative),
      'cancelled' => (l10n.lendStatusCancelled, context.textFaint),
      _ => (l10n.lendStatusActive, context.tealAccent),
    };
    return _pill(label, color);
  }

  /// Due-status pill for an active loan, derived from the same
  /// overdue / next_due / paid_ahead fields the aging section uses:
  /// overdue (any past-due installment) → "Overdue"; otherwise the
  /// earliest unpaid due date → "Due {date}"; otherwise, when the
  /// borrower is running ahead of the bill → "Paid ahead". Returns null
  /// when there's nothing schedule-related to show (e.g. a terminal loan
  /// or an open-ended loan with no schedule and no due date).
  Widget? _dueStatusPill(Map<String, dynamic> loan) {
    final status = (loan['status'] ?? 'active').toString();
    if (status != 'active') return null;
    final l10n = AppLocalizations.of(context);
    final overdue = loan['overdue'] == true;
    final paidAhead = loan['paid_ahead'] == true;
    final nextDue = loan['next_due']?.toString();
    if (overdue) {
      return _pill(l10n.lendingDueOverdue, context.negative);
    }
    if (nextDue != null && nextDue.isNotEmpty) {
      return _pill(l10n.lendingDueOn(_shortDate(nextDue)), context.warning);
    }
    if (paidAhead) {
      return _pill(l10n.lendingDuePaidAhead, context.positive);
    }
    return null;
  }

  /// Compact pill/badge — same chrome as the status pill so the
  /// due-status badge sits beside it without restyling.
  Widget _pill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.accentSoft(color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  /// "Jun 29" (en) / "29 jun" (es) from a YYYY-MM-DD due date; falls back
  /// to the raw string if it doesn't parse, so a malformed value never
  /// blanks the pill.
  String _shortDate(String ymd) => formatIsoDateShort(ymd);

  // ---------- add loan ----------

  Future<void> _openAddLoanDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => AddLoanDialog(
        apiService: widget.apiService,
        people: _people,
        defaultCurrency: widget.targetCurrency,
      ),
    );
    if (created == true) {
      await _load();
      widget.onChanged?.call();
    }
  }

  // ---------- interest income ----------

  /// Open the full interest-income drill-down (cash basis): per-month
  /// series, per-loan table, per-currency totals, and the §7872
  /// below-market callout. Read-only, so no refresh on close.
  Future<void> _openInterestIncome() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => InterestIncomeSheet(apiService: widget.apiService),
    );
  }

  // ---------- loan detail ----------

  Future<void> _openLoanDetail(Map<String, dynamic> loan) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => LoanDetailSheet(
        apiService: widget.apiService,
        loan: loan,
        // Live refresh on each in-sheet mutation: reload this tab's
        // loan list + tell the dashboard to refresh cash flow (loan-
        // linked transactions are excluded there).
        onMutated: () {
          _load();
          widget.onChanged?.call();
        },
        onOpenTransaction: widget.onOpenTransaction,
      ),
    );
    // Belt-and-braces: also refresh when the sheet closes (covers the
    // delete path, which pops true).
    if (changed == true) {
      await _load();
      widget.onChanged?.call();
    }
  }
}
