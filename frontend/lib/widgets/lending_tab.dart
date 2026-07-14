import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart' show MoneyDisplayFormat, moneyFormat;
import '../utils/flat_schedule.dart';
import '../utils/lending_summary.dart';
import '../utils/theme_colors.dart';
import 'interest_income_sheet.dart';

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
/// entrypoint so cross-widget callers don't need the private dialog class.
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
    builder: (_) => _AddLoanDialog(
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
        amount.toDouble(), fromCurrency, target, widget.usdMxnRate);
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
            Text(AppLocalizations.of(context).lendLoadError,
                style: TextStyle(color: context.textMuted)),
            const SizedBox(height: 12),
            FilledButton(
                onPressed: _load,
                child: Text(AppLocalizations.of(context).lendRetry)),
          ],
        ),
      );
    }

    // Thumb-zone creation on phones: the header drops its labelled
    // "Add loan" button (it overflowed at 390px) and the affordance moves
    // to a FAB pinned bottom-right. The list keeps 88dp of clearance so
    // the last loan card is never hidden under the FAB.
    final phone = MediaQuery.sizeOf(context).width < 720;
    final list = RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(bottom: phone ? 96 : 32),
        children: [
          _buildHeader(),
          if (_buildAgingSection() case final w?) ...[
            const SizedBox(height: 16),
            w,
          ],
          const SizedBox(height: 16),
          if (_loans.isEmpty)
            _buildEmptyState()
          else
            ..._loans.map((l) => _buildLoanCard(l as Map<String, dynamic>)),
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
  }

  /// Currency to denominate the summary stats in. When every loan shares
  /// one currency we show that native currency (no FX conversion) so a
  /// single MX$30,000 loan reads "MX$30,000", not its USD equivalent.
  /// Only a genuinely mixed portfolio falls back to the display currency.
  String _summaryCurrency() {
    if (_loans.isEmpty) return widget.targetCurrency;
    final first = _loans.first;
    if (first is Map) {
      return (first['currency'] ?? widget.targetCurrency).toString();
    }
    return widget.targetCurrency;
  }

  Widget _buildHeader() {
    // Single-currency portfolios show their native currency untouched;
    // only a genuinely mixed (USD + MXN) portfolio is converted to the
    // display currency at the spot rate (with the caveat note below).
    // When summaryCur equals a loan's own currency, sumLoansConverted's
    // convertCurrency hits its from==to early-return and leaves the
    // amount unchanged — so the header matches the per-loan cards.
    final mixed = loansAreMixedCurrency(_loans);
    final summaryCur = mixed ? widget.targetCurrency : _summaryCurrency();
    final totalLent =
        sumLoansConverted(_loans, 'principal', summaryCur, widget.usdMxnRate);
    // Total still owed across loans (principal + unpaid interest).
    final totalOut = sumLoansConverted(
        _loans, 'total_owed', summaryCur, widget.usdMxnRate);
    final interestEarned = sumLoansConverted(
        _loans, 'interest_earned', summaryCur, widget.usdMxnRate);
    final active = (_summary['active_count'] as num?)?.toInt() ?? 0;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    final phone = MediaQuery.sizeOf(context).width < 720;
    final outstandingTile = _stat(AppLocalizations.of(context).lendingOutstanding,
        _money(totalOut, summaryCur), context.warning);
    final totalLentTile = _stat(AppLocalizations.of(context).lendingTotalLent,
        _money(totalLent, summaryCur), context.textPrimary);
    final activeTile = _stat(AppLocalizations.of(context).lendingActive,
        '$active', context.tealAccent);
    // Interest income — the headline of this feature.
    final interestTile = _stat(AppLocalizations.of(context).lendingInterestEarned,
        _money(interestEarned, summaryCur), context.positive);
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
                // Flexible + ellipsis: the title yields to the action
                // cluster instead of RenderFlex-overflowing at narrow
                // widths (it did at 390px once interest was earned).
                Flexible(
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
                const Spacer(),
                // Drill into the full cash-basis interest-income report
                // (per-month series, per-loan + per-currency totals,
                // §7872 below-market flag). Only meaningful once interest
                // has actually been received. On phones the labelled
                // button shrinks to a 48dp icon so the header row fits.
                if (interestEarned > 0)
                  phone
                      ? IconButton(
                          icon: const Icon(Icons.insights_outlined),
                          tooltip: AppLocalizations.of(context)
                              .lendingInterestIncomeTitle,
                          onPressed: _openInterestIncome,
                        )
                      : TextButton.icon(
                          onPressed: _openInterestIncome,
                          icon: const Icon(Icons.insights_outlined, size: 18),
                          label: Text(AppLocalizations.of(context)
                              .lendingInterestIncomeTitle),
                        ),
                // Export the loan-interest CSV (cash-basis interest
                // income — hand to an accountant at tax time).
                if (interestEarned > 0)
                  PopupMenuButton<String>(
                    tooltip: AppLocalizations.of(context)
                        .lendExportInterestTooltip,
                    icon: const Icon(Icons.download_outlined),
                    onSelected: (which) {
                      final url = which == 'summary'
                          ? widget.apiService.interestSummaryCsvUrl()
                          : widget.apiService.interestIncomeCsvUrl();
                      launchUrl(Uri.parse(url),
                          webOnlyWindowName: '_self');
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'detail',
                        child: Text(AppLocalizations.of(context)
                            .lendExportPaymentsCsv),
                      ),
                      PopupMenuItem(
                        value: 'summary',
                        child: Text(AppLocalizations.of(context)
                            .lendExportYearEndCsv),
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
                  AppLocalizations.of(context)
                      .lendTotalsConvertedNote(summaryCur),
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
        Text(label,
            style: TextStyle(fontSize: 11, color: context.textSubtle)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
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
        return (order: 0, label: l10n.lendingAgingOverdue30, color: context.negative);
      }
      if (overdue >= 7) {
        return (order: 1, label: l10n.lendingAgingOverdue7, color: context.negative);
      }
      if (overdue >= 1) {
        return (order: 2, label: l10n.lendingAgingOverdue1, color: context.warning);
      }
      if (until <= 0) {
        return (order: 3, label: l10n.lendingAgingDueToday, color: context.warning);
      }
      return (order: 4, label: l10n.lendingAgingDueSoon, color: context.tealAccent);
    }

    // Sort: oldest-overdue first, then soonest-due. Within a band, the
    // most-overdue / soonest-due item leads.
    final items = _reminders
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
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
          Text(AppLocalizations.of(context).lendingNoLoans,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: context.textMuted)),
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

  Widget _buildLoanCard(Map<String, dynamic> loan) {
    final currency = (loan['currency'] ?? 'USD').toString();
    // "Outstanding" here means the TOTAL still owed (principal + unpaid
    // interest) so the card matches the loan detail + agreement — a
    // 14k-principal + 2k-interest loan reads "16,000". Falls back to the
    // principal-based outstanding for older payloads.
    final outstanding = (loan['total_owed'] as num?)?.toDouble() ??
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
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

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
                              AppLocalizations.of(context).lendUnknownBorrower)
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
                '${AppLocalizations.of(context).lendLentMeta(_money(principal, currency), (loan['origination_date'] ?? '').toString())}'
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
                    style: TextStyle(fontSize: 11, color: context.textFaint),
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
                      style: TextStyle(fontSize: 12, color: context.textMuted)),
                  Text(
                      '${AppLocalizations.of(context).lendingOutstanding} ${_money(outstanding, currency)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: outstanding > 0
                            ? context.warning
                            : context.positive,
                      )),
                ],
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
      Map<String, dynamic> loan, String currency, String status) {
    final earned = (loan['interest_earned'] as num?)?.toDouble() ?? 0;
    // Mirror the detail sheet: never surface an "owed" amount on a
    // terminal loan, even if a stale accrual slipped through.
    final terminal =
        status == 'paid_off' || status == 'cancelled' || status == 'written_off';
    final accrued =
        terminal ? 0.0 : (loan['interest_accrued'] as num?)?.toDouble() ?? 0;
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
              text:
                  '${l10n.lendingInterestEarned} ${_money(earned, currency)}',
              style: TextStyle(color: context.positive),
            ),
          if (earned > 0 && accrued > 0)
            TextSpan(
                text: ' · ',
                style: TextStyle(color: context.textFaint)),
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
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  /// "Jun 29" from a YYYY-MM-DD due date; falls back to the raw string if
  /// it doesn't parse, so a malformed value never blanks the pill.
  String _shortDate(String ymd) {
    final d = DateTime.tryParse(ymd);
    return d == null ? ymd : DateFormat('MMM d').format(d);
  }

  // ---------- add loan ----------

  Future<void> _openAddLoanDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _AddLoanDialog(
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
      builder: (_) =>
          InterestIncomeSheet(apiService: widget.apiService),
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
      builder: (_) => _LoanDetailSheet(
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

// =====================================================================
// Add-loan dialog
// =====================================================================

/// One editable installment row in the custom-schedule editor. Each row
/// owns its own controllers so an inline edit doesn't rebuild the whole
/// list (and keeps cursor position stable).
class _CustomRow {
  final TextEditingController dateCtrl;
  final TextEditingController amountCtrl;

  _CustomRow(this.dateCtrl, this.amountCtrl);

  factory _CustomRow.of(String date, String amount) => _CustomRow(
        TextEditingController(text: date),
        TextEditingController(text: amount),
      );

  void dispose() {
    dateCtrl.dispose();
    amountCtrl.dispose();
  }
}

class _AddLoanDialog extends StatefulWidget {
  final ApiService apiService;
  final List<dynamic> people;
  final String defaultCurrency;

  // Optional prefill — used by "Create loan from this transaction". When
  // [disbursementTxId] is set, the loan is linked to that transaction as
  // its disbursement after creation (and rolled back on a 409 conflict).
  final double? initialPrincipal;
  final String? initialCurrency;
  final DateTime? initialOriginationDate;
  final String? initialBorrowerName;
  final String? disbursementTxId;

  const _AddLoanDialog({
    required this.apiService,
    required this.people,
    required this.defaultCurrency,
    this.initialPrincipal,
    this.initialCurrency,
    this.initialOriginationDate,
    this.initialBorrowerName,
    this.disbursementTxId,
  });

  @override
  State<_AddLoanDialog> createState() => _AddLoanDialogState();
}

class _AddLoanDialogState extends State<_AddLoanDialog> {
  final _principalCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  final _termCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  // Latest borrower text, fed by the Autocomplete field's onChanged /
  // onSelected (avoids attaching a controller listener on every
  // fieldViewBuilder rebuild).
  String _borrowerText = '';
  String _currency = 'USD';
  String _interestType = 'none';
  // 'annual' or 'monthly' — the period the entered rate is in. Stored
  // faithfully so "1% / month" stays exact end-to-end.
  String _ratePeriod = 'annual';
  String _paymentFrequency = 'monthly';
  DateTime _originationDate = DateTime.now();
  // Optional "pay back by" date — works for any loan style, including a
  // no-interest open-ended loan that just needs a due date + reminder.
  DateTime? _expectedRepaymentDate;
  bool _submitting = false;
  // When true, the user enters the payment they can make and we solve
  // for the term (instead of entering a term and computing the payment).
  // Only offered for the loan styles where a fixed payment defines a
  // term — see [_supportsSolve].
  bool _setByPayment = false;
  // The per-period payment the borrower can make, for solve-by-payment.
  // Reused as the payment amount in flat-amount mode.
  final _paymentCtrl = TextEditingController();
  // Flat-interest, amount sub-mode: the agreed TOTAL interest (a fixed
  // peso/dollar figure, not a rate). Principal + this = what's owed; the
  // payment amount then determines how many installments.
  final _flatInterestCtrl = TextEditingController();
  // The "Flat interest" style covers two inputs of the SAME loan shape:
  // 'amount' (a fixed total → custom schedule) or 'rate' (a % → the 'simple'
  // backend type). Kept as a sub-toggle so the two don't read as rival tiles.
  String _flatMode = 'amount';
  // The three less-common styles (interest-only, one-payment-at-end, custom)
  // live behind this "More loan types" disclosure so the default view is the
  // three everyday choices.
  bool _showMoreStyles = false;
  // Rate period + payment frequency live behind this expander so the
  // default view isn't a wall of dropdowns.
  bool _showAdvanced = false;

  // ----- Custom-schedule mode (_interestType == 'custom') -----
  // The explicit installment rows the user pastes / edits. Each carries its
  // own controllers so an inline edit doesn't rebuild the whole list.
  final List<_CustomRow> _customRows = [];
  final _pasteCtrl = TextEditingController();
  bool _showCustomGenerator = false;
  // Quick-fill generator inputs.
  final _genFirstNCtrl = TextEditingController();
  final _genFirstAmtCtrl = TextEditingController();
  final _genThenAmtCtrl = TextEditingController();
  final _genDayCtrl = TextEditingController();
  DateTime? _genStart;
  DateTime? _genEnd;

  bool get _isCustom => _interestType == 'custom';
  // The merged "Flat interest" tile. Its 'amount' sub-mode submits as a
  // custom schedule (interest inferred); its 'rate' sub-mode submits as the
  // 'simple' backend type — same even-split schedule either way.
  bool get _isFlat => _interestType == 'flat';
  bool get _isFlatAmount => _isFlat && _flatMode == 'amount';
  // The advanced styles hidden behind "More loan types".
  static const _advancedStyles = ['interest_only', 'compound', 'custom'];
  // Backend interest_type for the current UI selection ('flat' is not a real
  // type — rate-mode is 'simple', amount-mode goes through the custom path).
  String get _backendInterestType => _isFlat ? 'simple' : _interestType;

  /// Native-currency symbol for the loan being entered (never the
  /// converted display currency — the preview always speaks the loan's
  /// own money).
  String get _sym => _currency == 'MXN' ? r'MX$' : r'$';

  /// Whether "set the payment, solve for the term" applies to the current
  /// selection. Only standard (amortized) and no-interest loans amortize
  /// from a fixed periodic payment; a lump sum has no recurring payment.
  bool get _supportsSolve =>
      (_interestType == 'amortized' || _interestType == 'none') &&
      _paymentFrequency != 'lump_sum';

  /// Live, approximate projection of this loan's finances for the preview
  /// card. Mirrors the backend schedule formulas (see lending_summary
  /// `projectLoan`); the penny-accurate schedule is still generated
  /// server-side in Decimal once the loan is saved.
  LoanProjection? _projection() => projectLoan(
        principal: double.tryParse(_principalCtrl.text.trim()),
        interestType: _backendInterestType,
        ratePercent: double.tryParse(_rateCtrl.text.trim()),
        ratePeriod: _ratePeriod,
        termMonths: int.tryParse(_termCtrl.text.trim()),
        paymentFrequency: _paymentFrequency,
      );

  String _fmtMoney(double v) => moneyFormat(_currency).format(v);

  @override
  void initState() {
    super.initState();
    final cur = widget.initialCurrency ?? widget.defaultCurrency;
    _currency = cur == 'MXN' ? 'MXN' : 'USD';
    if (widget.initialPrincipal != null && widget.initialPrincipal! > 0) {
      _principalCtrl.text = _trimZeros(widget.initialPrincipal!);
    }
    if (widget.initialOriginationDate != null) {
      _originationDate = widget.initialOriginationDate!;
    }
    if (widget.initialBorrowerName != null) {
      _borrowerText = widget.initialBorrowerName!;
    }
  }

  /// Amount without trailing ".00" so a prefilled principal shows cleanly.
  String _trimZeros(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _principalCtrl.dispose();
    _rateCtrl.dispose();
    _termCtrl.dispose();
    _paymentCtrl.dispose();
    _flatInterestCtrl.dispose();
    _notesCtrl.dispose();
    _pasteCtrl.dispose();
    _genFirstNCtrl.dispose();
    _genFirstAmtCtrl.dispose();
    _genThenAmtCtrl.dispose();
    _genDayCtrl.dispose();
    for (final r in _customRows) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peopleNames = widget.people
        .map((p) => (p as Map)['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 380;
    // Cap content at 460 but never exceed the viewport minus the AlertDialog's
    // 16px-per-side inset, or the dialog overflows off-screen on narrow windows.
    final dialogWidth =
        media.size.width - 32 < 460 ? media.size.width - 32 : 460.0;
    // Height the scrollable content may take. AlertDialog stacks the
    // title (~88) + actions (~64) + inset padding (48) on top of the
    // content, plus any keyboard inset — leave room for all of it so the
    // dialog never runs off a short viewport. Floor keeps it usable on
    // very small screens (content scrolls within this box).
    final contentMaxHeight =
        (media.size.height - media.viewInsets.bottom - 220)
            .clamp(220.0, 620.0);

    // Presentation-only split: the same title row, scrollable content
    // column, and action buttons render either as the classic AlertDialog
    // (>=720) or as a fullscreen phone form with a pinned save bar. All
    // controllers, state, and validation stay on this State either way.
    final titleRow = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: context.accentSoft(context.tealAccent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.monetization_on,
              color: context.tealAccent, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppLocalizations.of(context).lendingAddLoan,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary)),
              Text(AppLocalizations.of(context).lendAddLoanSubtitle,
                  style: TextStyle(fontSize: 12, color: context.textMuted)),
            ],
          ),
        ),
      ],
    );

    final contentColumn = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section(
                    AppLocalizations.of(context).lendSectionBorrowerAmount, [
                  Autocomplete<String>(
                    initialValue:
                        TextEditingValue(text: widget.initialBorrowerName ?? ''),
                    optionsBuilder: (value) {
                      if (value.text.isEmpty) return peopleNames;
                      return peopleNames.where((n) =>
                          n.toLowerCase().contains(value.text.toLowerCase()));
                    },
                    onSelected: (s) => _borrowerText = s,
                    fieldViewBuilder: (ctx, ctrl, focus, _) => TextField(
                      controller: ctrl,
                      focusNode: focus,
                      onChanged: (v) => _borrowerText = v,
                      decoration: _decoration(
                          AppLocalizations.of(context).lendFieldBorrowerName,
                          hint: 'e.g. Jose Ramirez',
                          icon: Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _principalCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: _decoration(
                        AppLocalizations.of(context).lendFieldAmountLent,
                        prefixText: '$_sym ',
                        icon: Icons.payments_outlined),
                  ),
                  const SizedBox(height: 12),
                  _twoUp(
                    narrow,
                    DropdownButtonFormField<String>(
                      initialValue: _currency,
                      isExpanded: true,
                      decoration: _decoration(
                          AppLocalizations.of(context).lendFieldCurrency),
                      items: const [
                        DropdownMenuItem(value: 'USD', child: Text('USD')),
                        DropdownMenuItem(value: 'MXN', child: Text('MXN')),
                      ],
                      onChanged: (v) =>
                          setState(() => _currency = v ?? 'USD'),
                    ),
                    InkWell(
                      onTap: _pickDate,
                      borderRadius: BorderRadius.circular(10),
                      child: InputDecorator(
                        decoration: _decoration(
                            AppLocalizations.of(context).lendFieldLentOn,
                            icon: Icons.event_outlined),
                        child: Text(
                          DateFormat('MMM d, y').format(_originationDate),
                          style: TextStyle(color: context.textPrimary),
                        ),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                _section(
                    AppLocalizations.of(context).lendSectionHowLoanWorks, [
                  // Plain-language loan styles replace the cryptic
                  // interest-type dropdown — each says how its plan works.
                  _loanStyleChooser(),
                  if (_isCustom) ...[
                    const SizedBox(height: 14),
                    _customScheduleEditor(narrow),
                  ] else if (_isFlat) ...[
                    const SizedBox(height: 14),
                    _flatModeToggle(),
                    const SizedBox(height: 14),
                    if (_flatMode == 'amount')
                      _flatAmountFields(narrow)
                    else ...[
                      // Rate sub-mode: same even-split loan, entered as a %.
                      _rateField(),
                      const SizedBox(height: 14),
                      _termOrPaymentControls(narrow),
                      _advancedPanel(narrow),
                    ],
                  ] else ...[
                    if (_interestType != 'none') ...[
                      const SizedBox(height: 14),
                      _rateField(),
                    ],
                    const SizedBox(height: 14),
                    _termOrPaymentControls(narrow),
                    _advancedPanel(narrow),
                  ],
                ]),
                const SizedBox(height: 16),
                _section(
                    AppLocalizations.of(context).lendSectionExpectedRepayment,
                    [
                  _expectedDateField(),
                ]),
                const SizedBox(height: 16),
                _section(AppLocalizations.of(context).lendSectionNotes, [
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 2,
                    decoration: _decoration(
                        AppLocalizations.of(context).lendFieldOptional,
                        hint: 'e.g. for the car deposit',
                        icon: Icons.notes_outlined),
                  ),
                ]),
                const SizedBox(height: 16),
                _buildPreviewCard(),
              ],
    );

    final cancelButton = TextButton(
      onPressed: _submitting ? null : () => Navigator.pop(context, false),
      child: Text(AppLocalizations.of(context).actionCancel),
    );
    // The one and only save affordance — both wrappers pin this exact
    // button (same _submit, same spinner state).
    final saveButton = FilledButton.icon(
      onPressed: _submitting ? null : _submit,
      icon: _submitting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.add, size: 18),
      label: Text(AppLocalizations.of(context).lendingAddLoan),
    );

    // Phones: a fullscreen form (no cramped 620px dialog well) with the
    // header up top, the fields scrolling in between, and the save bar
    // pinned at the bottom of the screen — research rubric principle 11.
    if (media.size.width < 720) {
      return Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(child: titleRow),
                    IconButton(
                      tooltip:
                          MaterialLocalizations.of(context).closeButtonTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context, false),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: contentColumn,
                ),
              ),
              // Pinned save bar. The viewInsets term keeps Save above the
              // keyboard even if this subtree is ever hosted outside a
              // Dialog; inside Dialog.fullscreen it reads 0 because the
              // Dialog itself already pads the route above the keyboard
              // and strips viewInsets from descendants (Builder scopes the
              // lookup to a descendant context for exactly that reason —
              // this State's context still sees the raw inset and would
              // double-pad).
              Builder(builder: (ctx) {
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, 8, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
                  child: Row(
                    children: [
                      cancelButton,
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(height: 48, child: saveButton),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      title: titleRow,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: contentMaxHeight,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(child: contentColumn),
        ),
      ),
      actions: [cancelButton, saveButton],
    );
  }

  /// A titled group of fields in a soft card, for visual structure.
  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: context.textSubtle,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }

  /// Two fields side-by-side on wide screens, stacked on narrow ones.
  Widget _twoUp(bool narrow, Widget a, Widget b) {
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [a, const SizedBox(height: 12), b],
      );
    }
    return Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ],
    );
  }

  /// Shared filled, rounded input styling for the dialog.
  InputDecoration _decoration(String label,
      {String? hint, String? prefixText, String? suffixText, IconData? icon}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefixText,
      suffixText: suffixText,
      prefixIcon: icon == null ? null : Icon(icon, size: 18),
      isDense: true,
      filled: true,
      fillColor: context.tint(0.03),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.tealAccent, width: 1.5),
      ),
    );
  }

  /// The three everyday styles, always visible. "Flat interest" is the
  /// merged rate-or-amount tile (see [_flatMode]).
  List<(String, String, String)> _primaryStyles(AppLocalizations l10n) => [
        ('none', l10n.lendInterestTypeNone, l10n.lendStyleNoInterestDesc),
        ('flat', l10n.lendStyleFlatLabel, l10n.lendStyleFlatDesc),
        ('amortized', l10n.lendStyleStandardLabel, l10n.lendStyleStandardDesc),
      ];

  /// The less-common styles, tucked behind "More loan types".
  List<(String, String, String)> _moreStyles(AppLocalizations l10n) => [
        (
          'interest_only',
          l10n.lendStyleInterestOnlyLabel,
          l10n.lendStyleInterestOnlyDesc
        ),
        ('compound', l10n.lendStylePayAtEndLabel, l10n.lendStylePayAtEndDesc),
        ('custom', l10n.lendCustomStyleLabel, l10n.lendCustomStyleDesc),
      ];

  Widget _loanStyleChooser() {
    final l10n = AppLocalizations.of(context);
    final primary = _primaryStyles(l10n);
    final more = _moreStyles(l10n);
    // Keep the disclosure open while one of its styles is the selection, so
    // the chosen tile is never hidden.
    final showMore = _showMoreStyles || _advancedStyles.contains(_interestType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < primary.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _loanStyleTile(
            value: primary[i].$1,
            label: primary[i].$2,
            desc: primary[i].$3,
          ),
        ],
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _showMoreStyles = !_showMoreStyles),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Icon(showMore ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: context.textSubtle),
                const SizedBox(width: 6),
                Text(l10n.lendMoreLoanTypes,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: context.textSubtle)),
              ],
            ),
          ),
        ),
        if (showMore)
          for (var i = 0; i < more.length; i++) ...[
            _loanStyleTile(
              value: more[i].$1,
              label: more[i].$2,
              desc: more[i].$3,
            ),
            if (i < more.length - 1) const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _loanStyleTile(
      {required String value, required String label, required String desc}) {
    final selected = _interestType == value;
    final accent = context.tealAccent;
    return InkWell(
      onTap: () => setState(() {
        _interestType = value;
        // Solve-by-payment only applies to standard / no-interest loans.
        if (!_supportsSolve) _setByPayment = false;
      }),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? context.accentSoft(accent) : context.tint(0.02),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? context.accentBorder(accent) : context.hairline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 18,
                color: selected ? accent : context.textFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(desc,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: context.textMuted,
                          height: 1.3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Either a term field, or — for the styles that amortize from a fixed
  /// payment — a toggle between entering the term and entering the
  /// payment (solving for the term).
  Widget _termOrPaymentControls(bool narrow) {
    final termField = TextField(
      controller: _termCtrl,
      keyboardType: TextInputType.number,
      onChanged: (_) => setState(() {}),
      decoration: _decoration(
          AppLocalizations.of(context).lendFieldTermMonths,
          hint: 'e.g. 12', icon: Icons.schedule_outlined),
    );
    if (!_supportsSolve) return termField;

    final cadence = _paymentFrequency == 'weekly' ? 'week' : 'month';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
                value: false,
                label:
                    Text(AppLocalizations.of(context).lendSegSetTheTerm)),
            ButtonSegment(
                value: true,
                label:
                    Text(AppLocalizations.of(context).lendSegSetThePayment)),
          ],
          selected: {_setByPayment},
          showSelectedIcon: false,
          style: ButtonStyle(
            textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.bodySmall),
            visualDensity: VisualDensity.compact,
          ),
          onSelectionChanged: (s) => setState(() => _setByPayment = s.first),
        ),
        const SizedBox(height: 12),
        if (_setByPayment)
          TextField(
            controller: _paymentCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: _decoration(
                AppLocalizations.of(context).lendFieldMostTheyCanPay,
                prefixText: '$_sym ',
                suffixText: '/ $cadence',
                icon: Icons.payments_outlined),
          )
        else
          termField,
      ],
    );
  }

  /// The interest-rate percent field (shared by the rate-mode of Flat
  /// interest and by the standard / interest-only / compound styles).
  Widget _rateField() {
    return TextField(
      controller: _rateCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
      decoration: _decoration(
        AppLocalizations.of(context).lendFieldInterestRate,
        hint: AppLocalizations.of(context).lendRateHintExample,
        icon: Icons.percent,
        suffixText: _ratePeriod == 'monthly'
            ? AppLocalizations.of(context).lendRatePerMonthSuffix
            : AppLocalizations.of(context).lendRatePerYearSuffix,
      ),
    );
  }

  /// The "Flat interest" sub-toggle: enter the interest as a fixed total
  /// amount, or as a percentage rate. Both yield the same even-split
  /// schedule — this keeps them one concept, not two rival tiles.
  Widget _flatModeToggle() {
    final l10n = AppLocalizations.of(context);
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'amount', label: Text(l10n.lendFlatModeAmount)),
        ButtonSegment(value: 'rate', label: Text(l10n.lendFlatModeRate)),
      ],
      selected: {_flatMode},
      showSelectedIcon: false,
      style: ButtonStyle(
        textStyle:
            WidgetStatePropertyAll(Theme.of(context).textTheme.bodySmall),
        visualDensity: VisualDensity.compact,
      ),
      onSelectionChanged: (s) => setState(() => _flatMode = s.first),
    );
  }

  /// Flat/agreed-interest inputs: a fixed TOTAL interest amount (not a
  /// rate) plus the periodic payment. The schedule is generated client-side
  /// and submitted as a custom schedule; the backend infers the interest as
  /// (Σpayments − principal), so it always matches what's entered here.
  Widget _flatAmountFields(bool narrow) {
    final l10n = AppLocalizations.of(context);
    final cadence = _paymentFrequency == 'weekly' ? 'week' : 'month';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _flatInterestCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: _decoration(
            l10n.lendFieldAgreedInterest,
            hint: 'e.g. 2000',
            prefixText: '$_sym ',
            icon: Icons.handshake_outlined,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _paymentCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: _decoration(
            l10n.lendFieldPaymentAmount,
            hint: 'e.g. 4000',
            prefixText: '$_sym ',
            suffixText: '/ $cadence',
            icon: Icons.payments_outlined,
          ),
        ),
      ],
    );
  }

  /// Rate period + payment frequency, tucked behind an expander so the
  /// default view isn't a wall of dropdowns. Sensible defaults (per year,
  /// monthly) mean most users never open it.
  Widget _advancedPanel(bool narrow) {
    final fields = <Widget>[
      if (_interestType != 'none')
        DropdownButtonFormField<String>(
          initialValue: _ratePeriod,
          isExpanded: true,
          decoration:
              _decoration(AppLocalizations.of(context).lendFieldRateIsPer),
          items: [
            DropdownMenuItem(
                value: 'annual',
                child: Text(AppLocalizations.of(context).lendRatePeriodYear)),
            DropdownMenuItem(
                value: 'monthly',
                child: Text(AppLocalizations.of(context).lendRatePeriodMonth)),
          ],
          onChanged: (v) => setState(() => _ratePeriod = v ?? 'annual'),
        ),
      DropdownButtonFormField<String>(
        initialValue: _paymentFrequency,
        isExpanded: true,
        decoration: _decoration(
            AppLocalizations.of(context).lendFieldPaymentFrequency),
        items: [
          DropdownMenuItem(
              value: 'monthly',
              child: Text(AppLocalizations.of(context).cfCadenceMonthly)),
          DropdownMenuItem(
              value: 'weekly',
              child: Text(AppLocalizations.of(context).cfCadenceWeekly)),
          DropdownMenuItem(
              value: 'lump_sum',
              child: Text(AppLocalizations.of(context).lendFreqLumpSum)),
        ],
        onChanged: (v) => setState(() {
          _paymentFrequency = v ?? 'monthly';
          // A lump sum has no recurring payment to solve a term from.
          if (_paymentFrequency == 'lump_sum') _setByPayment = false;
        }),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: context.textMuted),
                const SizedBox(width: 6),
                Text(AppLocalizations.of(context).lendAdvancedOptions,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.textMuted)),
              ],
            ),
          ),
        ),
        if (_showAdvanced)
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            fields[i],
          ],
      ],
    );
  }

  /// Always-visible projection so the user sees the finances before
  /// saving — including no-interest loans, where it shows the total to
  /// repay. Native currency only (never the converted display value).
  Widget _buildPreviewCard() {
    final accent = context.tealAccent;
    final rows = _isCustom
        ? _customPreviewRows(accent)
        : _isFlatAmount
            ? _flatPreviewRows(accent)
            : (_setByPayment && _supportsSolve)
                ? _solvePreviewRows(accent)
                : _termPreviewRows(accent);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.accentSoft(accent),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.accentBorder(accent)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_outlined, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(AppLocalizations.of(context).lendPreviewTitle,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent)),
              const Spacer(),
              Text(AppLocalizations.of(context).lendPreviewEstimate,
                  style: TextStyle(fontSize: 10, color: context.textSubtle)),
            ],
          ),
          const SizedBox(height: 10),
          ...rows,
        ],
      ),
    );
  }

  /// The default preview: given the term, what's the payment + totals.
  List<Widget> _flatPreviewRows(Color accent) {
    final l10n = AppLocalizations.of(context);
    final principal = double.tryParse(_principalCtrl.text.trim()) ?? 0;
    final interest = double.tryParse(_flatInterestCtrl.text.trim()) ?? 0;
    final payment = double.tryParse(_paymentCtrl.text.trim()) ?? 0;
    final total = principal + interest;
    final rows = (payment > 0 && total > 0)
        ? _flatScheduleRows(
            principal: principal, interest: interest, payment: payment)
        : const <Map<String, dynamic>>[];
    return [
      _previewRow(l10n.lendPreviewTotalToRepay, _fmtMoney(total), bold: true),
      const SizedBox(height: 6),
      _previewRow(l10n.lendCustomPreviewCount(rows.length), _fmtMoney(payment)),
    ];
  }

  List<Widget> _termPreviewRows(Color accent) {
    final proj = _projection();
    if (proj == null) {
      return [
        Text(AppLocalizations.of(context).lendPreviewEnterAmount,
            style: TextStyle(fontSize: 13, color: context.textSubtle)),
      ];
    }
    final l10n = AppLocalizations.of(context);
    final cadenceLabel = switch (proj.cadence) {
      'monthly' => '/mo',
      'weekly' => '/wk',
      _ => '',
    };
    // Recurring-payment value: base "amount/cadence", optionally labelled as
    // interest (interest-only loans) and suffixed with the payment count.
    String perPaymentValue() {
      final base = '${_fmtMoney(proj.perPayment!)}$cadenceLabel';
      if (proj.periods == null) return base;
      return proj.balloonPayment != null
          ? l10n.lendPreviewPerPaymentInterest(
              _fmtMoney(proj.perPayment!), cadenceLabel, proj.periods!)
          : l10n.lendPreviewPerPaymentCount(
              _fmtMoney(proj.perPayment!), cadenceLabel, proj.periods!);
    }

    return [
        _previewRow(l10n.lendPreviewTotalToRepay,
            _fmtMoney(proj.totalRepayment),
            bold: true),
        const SizedBox(height: 6),
        if (proj.totalInterest > 0.005)
          _previewRow(
              l10n.lendPreviewProjectedInterest,
              _fmtMoney(proj.totalInterest),
              color: accent)
        else
          Text(l10n.lendPreviewNoInterest,
              style: TextStyle(fontSize: 12, color: context.textMuted)),
        if (proj.perPayment != null) ...[
          const SizedBox(height: 6),
          _previewRow(
            proj.cadence == 'balloon'
                ? l10n.lendPreviewSinglePayment
                : l10n.lendPreviewPayment,
            proj.cadence == 'balloon'
                ? _fmtMoney(proj.perPayment!)
                // Interest-only loans pay interest periodically, so label the
                // recurring figure as such — otherwise "$125/mo · 12 payments"
                // reads as the whole obligation when it's just the interest.
                : perPaymentValue(),
          ),
          // Interest-only: the principal balloons on the final installment,
          // so the borrower's last payment is the interest PLUS this amount.
          if (proj.balloonPayment != null && proj.balloonPayment! > 0.005) ...[
            const SizedBox(height: 6),
            _previewRow(
              l10n.lendPreviewPrincipalAtMaturity,
              l10n.lendPreviewDueWithFinalPayment(
                  _fmtMoney(proj.balloonPayment!)),
            ),
          ],
        ] else ...[
          const SizedBox(height: 6),
          Text(l10n.lendPreviewOpenEnded,
              style: TextStyle(fontSize: 12, color: context.textSubtle)),
        ],
    ];
  }

  /// Solve-for-term preview: given the payment the borrower can make, how
  /// many payments it takes, roughly how long, and the total cost.
  List<Widget> _solvePreviewRows(Color accent) {
    final res = solveTermFromPayment(
      principal: double.tryParse(_principalCtrl.text.trim()),
      interestType: _interestType,
      ratePercent: double.tryParse(_rateCtrl.text.trim()),
      ratePeriod: _ratePeriod,
      paymentFrequency: _paymentFrequency,
      targetPayment: double.tryParse(_paymentCtrl.text.trim()),
    );
    final cadence = _paymentFrequency == 'weekly' ? 'wk' : 'mo';
    if (!res.ok) {
      return [
        Text(
            res.reason ??
                AppLocalizations.of(context).lendPreviewEnterPaymentSolve,
            style: TextStyle(fontSize: 13, color: context.textSubtle)),
        if (res.minimumPayment != null) ...[
          const SizedBox(height: 6),
          _previewRow(AppLocalizations.of(context).lendPreviewMinimumPayment,
              '${_fmtMoney(res.minimumPayment!)}/$cadence',
              color: accent),
        ],
      ];
    }
    final l10n = AppLocalizations.of(context);
    final months = res.termMonths!;
    final years = months / 12.0;
    final termLabel = months < 12
        ? l10n.lendTermMonths(months)
        : l10n.lendTermYearsAbbrev(
            years.toStringAsFixed(months % 12 == 0 ? 0 : 1));
    return [
      _previewRow(l10n.lendPreviewPaidOffIn,
          l10n.lendPreviewPaidOffValue(res.periods!, termLabel),
          bold: true),
      const SizedBox(height: 6),
      if (res.totalInterest! > 0.005)
        _previewRow(l10n.lendPreviewProjectedInterest,
            _fmtMoney(res.totalInterest!),
            color: accent)
      else
        Text(l10n.lendPreviewNoInterest,
            style: TextStyle(fontSize: 12, color: context.textMuted)),
      const SizedBox(height: 6),
      _previewRow(
          l10n.lendPreviewTotalToRepay, _fmtMoney(res.totalRepayment!)),
    ];
  }

  Widget _previewRow(String label, String value,
      {bool bold = false, Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: context.textMuted)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: color ?? context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  // ===================================================================
  // Custom-schedule editor
  // ===================================================================

  /// The paste box + editable row list + quick-fill generator. The rows
  /// are the source of truth for the schedule that's saved on confirm.
  Widget _customScheduleEditor(bool narrow) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.lendCustomPasteTitle,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: context.textSubtle)),
        const SizedBox(height: 8),
        TextField(
          controller: _pasteCtrl,
          maxLines: 4,
          minLines: 3,
          style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()], fontSize: 13),
          decoration: _decoration(l10n.lendCustomPasteTitle,
              hint: l10n.lendCustomPasteHint),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _parsePaste,
            icon: const Icon(Icons.content_paste_go, size: 16),
            label: Text(l10n.lendCustomPasteButton,
                style: const TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 12),
        // Editable rows.
        Row(
          children: [
            Expanded(
              child: Text(l10n.lendCustomRowsTitle,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: context.textSubtle)),
            ),
            TextButton.icon(
              onPressed: _addCustomRow,
              icon: const Icon(Icons.add, size: 16),
              label: Text(l10n.lendCustomAddRow,
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_customRows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l10n.lendCustomNoRows,
                style: TextStyle(fontSize: 12, color: context.textSubtle)),
          )
        else
          for (var i = 0; i < _customRows.length; i++) _customRowTile(i),
        const SizedBox(height: 8),
        _customGeneratorPanel(narrow),
      ],
    );
  }

  Widget _customRowTile(int index) {
    final l10n = AppLocalizations.of(context);
    final row = _customRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            child: Text('${index + 1}',
                style: TextStyle(fontSize: 12, color: context.textFaint)),
          ),
          Expanded(
            flex: 4,
            child: TextField(
              controller: row.dateCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13),
              decoration: _decoration(l10n.lendCustomRowDate,
                  hint: 'YYYY-MM-DD'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13),
              decoration:
                  _decoration(l10n.lendCustomRowAmount, prefixText: '$_sym '),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: l10n.lendCustomRemoveRow,
            onPressed: () => _removeCustomRow(index),
          ),
        ],
      ),
    );
  }

  Widget _customGeneratorPanel(bool narrow) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () =>
              setState(() => _showCustomGenerator = !_showCustomGenerator),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(_showCustomGenerator ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: context.textMuted),
                const SizedBox(width: 6),
                Text(l10n.lendCustomGeneratorTitle,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.textMuted)),
              ],
            ),
          ),
        ),
        if (_showCustomGenerator) ...[
          _twoUp(
            narrow,
            TextField(
              controller: _genFirstNCtrl,
              keyboardType: TextInputType.number,
              decoration: _decoration(l10n.lendCustomGenFirstN, hint: '1'),
            ),
            TextField(
              controller: _genFirstAmtCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _decoration(l10n.lendCustomGenFirstAmount,
                  prefixText: '$_sym '),
            ),
          ),
          const SizedBox(height: 12),
          _twoUp(
            narrow,
            TextField(
              controller: _genThenAmtCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: _decoration(l10n.lendCustomGenThenAmount,
                  prefixText: '$_sym '),
            ),
            TextField(
              controller: _genDayCtrl,
              keyboardType: TextInputType.number,
              decoration: _decoration(l10n.lendCustomGenDayOfMonth, hint: '15'),
            ),
          ),
          const SizedBox(height: 12),
          _twoUp(
            narrow,
            InkWell(
              onTap: () => _pickGenDate(true),
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: _decoration(l10n.lendCustomGenStart,
                    icon: Icons.event_outlined),
                child: Text(
                  _genStart == null
                      ? '—'
                      : DateFormat('MMM d, y').format(_genStart!),
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                ),
              ),
            ),
            InkWell(
              onTap: () => _pickGenDate(false),
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: _decoration(l10n.lendCustomGenEnd,
                    icon: Icons.event_outlined),
                child: Text(
                  _genEnd == null
                      ? '—'
                      : DateFormat('MMM d, y').format(_genEnd!),
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _applyGenerator,
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: Text(l10n.lendCustomGenApply,
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickGenDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _genStart : _genEnd) ?? _originationDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _genStart = picked;
        } else {
          _genEnd = picked;
        }
      });
    }
  }

  /// Parse the pasted spreadsheet text into rows. Each non-empty line is
  /// split on a tab or a run of whitespace into a date + amount. Accepts
  /// M/D/YYYY, MM/DD/YYYY and YYYY-MM-DD; strips currency symbols/commas.
  void _parsePaste() {
    final text = _pasteCtrl.text;
    if (text.trim().isEmpty) {
      _toast(AppLocalizations.of(context).lendCustomPasteEmpty);
      return;
    }
    final parsed = <_CustomRow>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // Prefer a tab split (spreadsheet paste); fall back to whitespace.
      List<String> parts =
          line.contains('\t') ? line.split('\t') : line.split(RegExp(r'\s{2,}|\s+'));
      parts = parts.where((p) => p.trim().isNotEmpty).toList();
      if (parts.length < 2) continue;
      final iso = _normalizeDate(parts[0].trim());
      final amt = _parseAmount(parts.sublist(1).join(' '));
      if (iso == null || amt == null) continue;
      parsed.add(_CustomRow.of(iso, _trimZeros(amt)));
    }
    if (parsed.isEmpty) {
      _toast(AppLocalizations.of(context).lendCustomPasteEmpty);
      return;
    }
    setState(() {
      for (final r in _customRows) {
        r.dispose();
      }
      _customRows
        ..clear()
        ..addAll(parsed);
    });
    _toast(AppLocalizations.of(context).lendCustomPastedN(parsed.length));
  }

  /// Normalize a date token to YYYY-MM-DD, or null if unrecognized.
  String? _normalizeDate(String s) {
    final t = s.trim();
    // Already ISO (YYYY-MM-DD).
    final isoMatch = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(t);
    if (isoMatch != null) {
      return _iso(int.parse(isoMatch.group(1)!), int.parse(isoMatch.group(2)!),
          int.parse(isoMatch.group(3)!));
    }
    // M/D/YYYY or MM/DD/YYYY (US order — matches Google Sheets exports).
    final slash = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(t);
    if (slash != null) {
      var year = int.parse(slash.group(3)!);
      if (year < 100) year += 2000;
      return _iso(year, int.parse(slash.group(1)!), int.parse(slash.group(2)!));
    }
    return null;
  }

  String _iso(int y, int m, int d) =>
      '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

  /// Strip currency symbols / thousands separators and parse the amount.
  double? _parseAmount(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\d.\-]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  void _addCustomRow() {
    setState(() => _customRows.add(_CustomRow.of('', '')));
  }

  void _removeCustomRow(int index) {
    setState(() {
      _customRows.removeAt(index).dispose();
    });
  }

  /// Quick-fill: first N payments of X, then Y every month on day D from
  /// START to END. Replaces the current rows. A convenience only — the
  /// user can still fine-tune afterwards.
  void _applyGenerator() {
    final firstN = int.tryParse(_genFirstNCtrl.text.trim()) ?? 0;
    final firstAmt = _parseAmount(_genFirstAmtCtrl.text.trim());
    final thenAmt = _parseAmount(_genThenAmtCtrl.text.trim());
    final day = int.tryParse(_genDayCtrl.text.trim());
    final start = _genStart;
    final end = _genEnd;
    if (thenAmt == null || day == null || start == null || end == null) {
      _toast(AppLocalizations.of(context).lendCustomNeedRows);
      return;
    }
    final rows = <_CustomRow>[];
    // Walk month-by-month on the given day-of-month, from the start month
    // through (inclusive) the end month. The first [firstN] payments use
    // [firstAmt] (when given), the rest use [thenAmt]. Guard the loop at
    // 600 iterations so a bad end date can't spin forever.
    final endMonth = DateTime(end.year, end.month);
    var y = start.year;
    var m = start.month;
    var iter = 0;
    while (iter < 600 && !DateTime(y, m).isAfter(endMonth)) {
      final dim = DateUtils.getDaysInMonth(y, m);
      final d = day > dim ? dim : day;
      final amt =
          (rows.length < firstN && firstAmt != null) ? firstAmt : thenAmt;
      rows.add(_CustomRow.of(_iso(y, m, d), _trimZeros(amt)));
      iter++;
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }
    if (rows.isEmpty) {
      _toast(AppLocalizations.of(context).lendCustomNeedRows);
      return;
    }
    setState(() {
      for (final r in _customRows) {
        r.dispose();
      }
      _customRows
        ..clear()
        ..addAll(rows);
    });
  }

  /// Sum of the current custom rows' amounts (parsed; unparseable = 0).
  double _customSum() {
    var sum = 0.0;
    for (final r in _customRows) {
      sum += _parseAmount(r.amountCtrl.text.trim()) ?? 0;
    }
    return sum;
  }

  /// The preview for custom mode: count, sum, and whether it closes to 0.
  List<Widget> _customPreviewRows(Color accent) {
    final l10n = AppLocalizations.of(context);
    final principal = double.tryParse(_principalCtrl.text.trim());
    final sum = _customSum();
    final n = _customRows.length;
    final closes =
        principal != null && (sum - principal).abs() < 0.005 && n > 0;
    return [
      _previewRow(l10n.lendCustomPreviewCount(n), _fmtMoney(sum), bold: true),
      const SizedBox(height: 6),
      _previewRow(l10n.lendCustomPreviewSum, _fmtMoney(sum)),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(closes ? Icons.check_circle : Icons.warning_amber_rounded,
              size: 16, color: closes ? context.positive : context.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              closes
                  ? l10n.lendCustomClosesToZero
                  : l10n.lendCustomDoesNotAddUp(
                      _fmtMoney(sum),
                      principal == null ? _fmtMoney(0) : _fmtMoney(principal)),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: closes ? context.positive : context.warning,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _originationDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _originationDate = picked);
  }

  // Optional, clearable "pay back by" date. A repayment is in the future, so
  // (unlike "Lent on") the picker allows future dates.
  Future<void> _pickExpectedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expectedRepaymentDate ??
          _originationDate.add(const Duration(days: 30)),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _expectedRepaymentDate = picked);
  }

  Widget _expectedDateField() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: _pickExpectedDate,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              decoration: _decoration(
                  AppLocalizations.of(context).lendFieldPayBackBy,
                  icon: Icons.event_available_outlined),
              child: Text(
                _expectedRepaymentDate == null
                    ? 'Optional — when do they pay it back?'
                    : DateFormat('MMM d, y').format(_expectedRepaymentDate!),
                style: TextStyle(
                  color: _expectedRepaymentDate == null
                      ? context.textFaint
                      : context.textPrimary,
                ),
              ),
            ),
          ),
        ),
        if (_expectedRepaymentDate != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: AppLocalizations.of(context).lendTooltipClearDate,
            onPressed: () => setState(() => _expectedRepaymentDate = null),
          ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_isCustom) {
      await _submitCustom();
      return;
    }
    if (_isFlatAmount) {
      await _submitFlat();
      return;
    }
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(AppLocalizations.of(context).lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(AppLocalizations.of(context).lendToastEnterValidAmount);
      return;
    }
    setState(() => _submitting = true);
    try {
      // Rate entered as a percent; backend wants a fraction. The period
      // (year/month) is passed through verbatim so it's stored exactly.
      final isNone = _interestType == 'none';
      // Flat-interest rate mode maps to the 'simple' backend type.
      final backendType = _backendInterestType;
      final ratePct = double.tryParse(_rateCtrl.text.trim()) ?? 0;

      // Resolve the term: either typed directly, or solved from the
      // payment the borrower can make. A fixed schedule needs both a term
      // and a frequency; leaving the term blank makes the loan open-ended.
      int? term;
      if (_setByPayment && _supportsSolve) {
        final res = solveTermFromPayment(
          principal: principal,
          interestType: backendType,
          ratePercent: isNone ? 0 : ratePct,
          ratePeriod: _ratePeriod,
          paymentFrequency: _paymentFrequency,
          targetPayment: double.tryParse(_paymentCtrl.text.trim()),
        );
        if (!res.ok) {
          setState(() => _submitting = false);
          _toast(res.reason ??
              AppLocalizations.of(context).lendToastEnterPaymentCompute);
          return;
        }
        term = res.termMonths;
      } else {
        term = int.tryParse(_termCtrl.text.trim());
      }

      final loan = await widget.apiService.createLoan(
        borrowerName: borrower,
        principal: principal,
        currency: _currency,
        originationDate: _originationDate,
        interestRate: isNone ? 0 : ratePct / 100.0,
        interestType: backendType,
        ratePeriod: _ratePeriod,
        termMonths: term,
        // A frequency only makes sense alongside a fixed term; without one
        // the loan is open-ended (repayments recorded ad hoc).
        paymentFrequency: term != null ? _paymentFrequency : null,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        expectedRepaymentDate: _expectedRepaymentDate,
      );
      // Prefill flow: also link the funding transaction. Roll the loan back
      // on a 409 so we never leave an orphan loan whose disbursement failed.
      if (widget.disbursementTxId != null) {
        final ok = await _linkDisbursementOrRollback(loan['id'].toString());
        if (!ok) return;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(AppLocalizations.of(context).lendToastFailedToAddLoan);
    }
  }

  /// Custom-schedule confirm: create the loan (interest_type 'custom'),
  /// push the explicit rows, then optionally link the disbursement. On any
  /// failure after the loan is created, delete it so no empty loan is left.
  Future<void> _submitCustom() async {
    final l10n = AppLocalizations.of(context);
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(AppLocalizations.of(context).lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(AppLocalizations.of(context).lendToastEnterValidAmount);
      return;
    }
    final rows = _customScheduleRows();
    if (rows.isEmpty) {
      _toast(l10n.lendCustomNeedRows);
      return;
    }
    await _createLoanWithSchedule(principal, rows);
  }

  /// Flat/agreed-interest confirm: generate the installment rows from
  /// (principal + agreed interest) / payment, then create the loan as a
  /// custom schedule (same create-then-schedule flow as [_submitCustom]).
  Future<void> _submitFlat() async {
    final l10n = AppLocalizations.of(context);
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(l10n.lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(l10n.lendToastEnterValidAmount);
      return;
    }
    final interest = double.tryParse(_flatInterestCtrl.text.trim()) ?? 0;
    final payment = double.tryParse(_paymentCtrl.text.trim());
    if (interest < 0 || payment == null || payment <= 0) {
      _toast(l10n.lendToastEnterValidAmount);
      return;
    }
    final rows = _flatScheduleRows(
        principal: principal, interest: interest, payment: payment);
    if (rows.isEmpty) {
      // Payment too small to ever clear the balance (would need > the cap).
      _toast(l10n.lendToastEnterValidAmount);
      return;
    }
    await _createLoanWithSchedule(principal, rows);
  }

  /// Shared create-then-schedule flow for the custom and flat-amount styles:
  /// create the loan (interest_type 'custom'), push the explicit rows, then
  /// optionally link the disbursement. On any failure after the loan is
  /// created, delete it so no empty loan is left behind.
  Future<void> _createLoanWithSchedule(
      double principal, List<Map<String, dynamic>> rows) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _submitting = true);
    String? loanId;
    try {
      final loan = await widget.apiService.createLoan(
        borrowerName: _borrowerText.trim(),
        principal: principal,
        currency: _currency,
        originationDate: _originationDate,
        interestRate: 0,
        interestType: 'custom',
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        expectedRepaymentDate: _expectedRepaymentDate,
      );
      loanId = loan['id'].toString();
      await widget.apiService.setCustomSchedule(loanId, rows);
      if (widget.disbursementTxId != null) {
        final ok = await _linkDisbursementOrRollback(loanId);
        if (!ok) return;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      // Roll back the just-created loan so a failed schedule doesn't leave
      // an empty loan behind.
      if (loanId != null) {
        try {
          await widget.apiService.deleteLoan(loanId);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(l10n.lendCustomScheduleFailed(e.toString()));
    }
  }

  /// Build the flat-amount installment rows from the current inputs. Pure
  /// generation lives in [buildFlatSchedule] (unit-tested).
  List<Map<String, dynamic>> _flatScheduleRows({
    required double principal,
    required double interest,
    required double payment,
  }) =>
      buildFlatSchedule(
        principal: principal,
        interest: interest,
        payment: payment,
        origination: _originationDate,
        frequency: _paymentFrequency,
      );

  /// Link [loanId]'s disbursement to the prefilled transaction. Returns true
  /// on success; on a 409 conflict (tx already funds another loan) it deletes
  /// the loan, shows a message and returns false. Any other failure rethrows.
  Future<bool> _linkDisbursementOrRollback(String loanId) async {
    try {
      await widget.apiService.linkDisbursement(loanId, widget.disbursementTxId!);
      return true;
    } on DisbursementConflictException {
      try {
        await widget.apiService.deleteLoan(loanId);
      } catch (_) {}
      if (!mounted) return false;
      setState(() => _submitting = false);
      _toast(AppLocalizations.of(context).lendDisbursementConflict);
      return false;
    }
  }

  /// The custom rows as the API payload: `{due_date, amount}`, dropping any
  /// row whose date or amount doesn't parse.
  List<Map<String, dynamic>> _customScheduleRows() {
    final rows = <Map<String, dynamic>>[];
    for (final r in _customRows) {
      final iso = _normalizeDate(r.dateCtrl.text.trim());
      final amt = _parseAmount(r.amountCtrl.text.trim());
      if (iso == null || amt == null) continue;
      rows.add({'due_date': iso, 'amount': amt});
    }
    return rows;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// =====================================================================
// Edit-loan dialog — correct borrower / principal / rate / type / notes
// =====================================================================

/// Mirrors the add-loan dialog's look (same _section / _twoUp / filled
/// inputs) but only exposes the fields the backend PATCH accepts:
/// borrower_name, principal, interest_rate, interest_type, notes.
/// rate_period / term / payment frequency are NOT in UpdateLoanRequest,
/// so they're shown read-only for context. Pops a map of the changed
/// fields (display shape — `principal`/`interest_rate` as numbers,
/// `interest_rate` still a fraction) on success, or null on cancel.
class _EditLoanDialog extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> loan;

  const _EditLoanDialog({
    required this.apiService,
    required this.loan,
  });

  @override
  State<_EditLoanDialog> createState() => _EditLoanDialogState();
}

class _EditLoanDialogState extends State<_EditLoanDialog> {
  late final TextEditingController _borrowerCtrl;
  late final TextEditingController _principalCtrl;
  late final TextEditingController _rateCtrl;
  late final TextEditingController _notesCtrl;
  late String _interestType;
  DateTime? _expectedRepaymentDate;
  bool _submitting = false;

  String get _currency =>
      (widget.loan['currency'] ?? 'USD').toString();
  String get _sym => _currency == 'MXN' ? r'MX$' : r'$';
  String get _ratePeriod =>
      (widget.loan['rate_period'] ?? 'annual').toString();

  @override
  void initState() {
    super.initState();
    _borrowerCtrl = TextEditingController(
        text: (widget.loan['borrower_name'] ?? '').toString());
    final principal = (widget.loan['principal'] as num?)?.toDouble() ?? 0;
    _principalCtrl = TextEditingController(
        text: principal == 0 ? '' : _trimZeros(principal));
    // Stored as a fraction; show as a percent (×100), mirroring add-loan.
    final rateFraction =
        (widget.loan['interest_rate'] as num?)?.toDouble() ?? 0;
    _rateCtrl = TextEditingController(
        text: rateFraction == 0 ? '' : _trimZeros(rateFraction * 100));
    _notesCtrl = TextEditingController(
        text: (widget.loan['notes'] ?? '').toString());
    _interestType = (widget.loan['interest_type'] ?? 'none').toString();
    final erd = widget.loan['expected_repayment_date'];
    _expectedRepaymentDate =
        erd == null ? null : DateTime.tryParse(erd.toString());
  }

  Future<void> _pickExpectedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _expectedRepaymentDate ?? DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _expectedRepaymentDate = picked);
  }

  Widget _expectedDateField() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: _pickExpectedDate,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              decoration: _decoration(
                  AppLocalizations.of(context).lendFieldPayBackBy,
                  icon: Icons.event_available_outlined),
              child: Text(
                _expectedRepaymentDate == null
                    ? 'Optional — when do they pay it back?'
                    : DateFormat('MMM d, y').format(_expectedRepaymentDate!),
                style: TextStyle(
                  color: _expectedRepaymentDate == null
                      ? context.textFaint
                      : context.textPrimary,
                ),
              ),
            ),
          ),
        ),
        if (_expectedRepaymentDate != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: AppLocalizations.of(context).lendTooltipClearDate,
            onPressed: () => setState(() => _expectedRepaymentDate = null),
          ),
      ],
    );
  }

  /// Format a double for an editable field without a trailing ".0".
  String _trimZeros(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('.00')
        ? s.substring(0, s.length - 3)
        : (s.endsWith('0') ? s.substring(0, s.length - 1) : s);
  }

  @override
  void dispose() {
    _borrowerCtrl.dispose();
    _principalCtrl.dispose();
    _rateCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final contentMaxHeight =
        (media.size.height - media.viewInsets.bottom - 220)
            .clamp(220.0, 620.0);
    final dialogWidth =
        media.size.width - 32 < 460 ? media.size.width - 32 : 460.0;
    final readOnlyTerms = _termsSummary();

    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: context.accentSoft(context.tealAccent),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.edit_outlined,
                color: context.tealAccent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppLocalizations.of(context).lendEditLoanTitle,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary)),
                Text(AppLocalizations.of(context).lendEditLoanSubtitle,
                    style: TextStyle(fontSize: 12, color: context.textMuted)),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: contentMaxHeight,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section(
                    AppLocalizations.of(context).lendSectionBorrowerAmount, [
                  TextField(
                    controller: _borrowerCtrl,
                    decoration: _decoration(
                        AppLocalizations.of(context).lendFieldBorrowerName,
                        icon: Icons.person_outline),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _principalCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: _decoration(
                        AppLocalizations.of(context).lendFieldAmountLent,
                        prefixText: '$_sym ',
                        icon: Icons.payments_outlined),
                  ),
                ]),
                const SizedBox(height: 16),
                _section(
                    AppLocalizations.of(context).lendSectionInterestTerms, [
                  DropdownButtonFormField<String>(
                    initialValue: _interestType,
                    isExpanded: true,
                    decoration: _decoration(
                        AppLocalizations.of(context).lendFieldInterestType),
                    items: [
                      DropdownMenuItem(
                          value: 'none',
                          child: Text(AppLocalizations.of(context)
                              .lendInterestTypeNone)),
                      DropdownMenuItem(
                          value: 'simple',
                          child: Text(AppLocalizations.of(context)
                              .lendInterestTypeSimple)),
                      DropdownMenuItem(
                          value: 'amortized',
                          child: Text(AppLocalizations.of(context)
                              .lendInterestTypeAmortized)),
                      DropdownMenuItem(
                          value: 'interest_only',
                          child: Text(AppLocalizations.of(context)
                              .lendInterestTypeInterestOnly)),
                      DropdownMenuItem(
                          value: 'compound',
                          child: Text(AppLocalizations.of(context)
                              .lendInterestTypeCompound)),
                    ],
                    onChanged: (v) =>
                        setState(() => _interestType = v ?? 'none'),
                  ),
                  if (_interestType != 'none') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _rateCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: _decoration(
                          AppLocalizations.of(context)
                              .lendEditRatePerPeriod(_ratePeriod),
                          hint: AppLocalizations.of(context)
                              .lendRateHintExample,
                          icon: Icons.percent),
                    ),
                  ],
                  if (readOnlyTerms != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      readOnlyTerms,
                      style:
                          TextStyle(fontSize: 11, color: context.textSubtle),
                    ),
                  ],
                ]),
                const SizedBox(height: 16),
                _section(
                    AppLocalizations.of(context).lendSectionExpectedRepayment,
                    [
                  _expectedDateField(),
                ]),
                const SizedBox(height: 16),
                _section(AppLocalizations.of(context).lendSectionNotes, [
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 2,
                    decoration: _decoration(
                        AppLocalizations.of(context).lendFieldOptional,
                        hint: 'e.g. for the car deposit',
                        icon: Icons.notes_outlined),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).actionCancel),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check, size: 18),
          label: Text(AppLocalizations.of(context).lendSaveChanges),
        ),
      ],
    );
  }

  /// Read-only summary of the term / payment-frequency fields the PATCH
  /// endpoint doesn't accept, so the user understands why they're not
  /// editable here. Null when the loan is open-ended (nothing to show).
  String? _termsSummary() {
    final term = (widget.loan['term_months'] as num?)?.toInt();
    final freq = widget.loan['payment_frequency']?.toString();
    if (term == null && (freq == null || freq.isEmpty)) return null;
    final l10n = AppLocalizations.of(context);
    final parts = <String>[];
    if (term != null) parts.add(l10n.lendTermsSummaryTermMonths(term));
    if (freq != null && freq.isNotEmpty) {
      parts.add(switch (freq) {
        'monthly' => l10n.lendTermsSummaryMonthlyPayments,
        'weekly' => l10n.lendTermsSummaryWeeklyPayments,
        'lump_sum' => l10n.lendTermsSummaryLumpSumPayment,
        _ => '$freq payments',
      });
    }
    return l10n.lendTermsSummaryFixed(parts.join(' · '));
  }

  /// A titled group of fields in a soft card (mirrors _AddLoanDialog).
  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: context.textSubtle,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }

  /// Shared filled, rounded input styling (mirrors _AddLoanDialog).
  InputDecoration _decoration(String label,
      {String? hint, String? prefixText, IconData? icon}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefixText,
      prefixIcon: icon == null ? null : Icon(icon, size: 18),
      isDense: true,
      filled: true,
      fillColor: context.tint(0.03),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.tealAccent, width: 1.5),
      ),
    );
  }

  Future<void> _submit() async {
    final borrower = _borrowerCtrl.text.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(AppLocalizations.of(context).lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(AppLocalizations.of(context).lendToastEnterValidAmount);
      return;
    }
    final interestBearing = _interestType != 'none';
    // Rate entered as a percent; backend wants a fraction (mirrors
    // add-loan). A non-interest loan stores a 0 rate.
    final ratePct =
        interestBearing ? (double.tryParse(_rateCtrl.text.trim()) ?? 0) : 0.0;
    final rateFraction = ratePct / 100.0;
    final notes = _notesCtrl.text.trim();

    setState(() => _submitting = true);
    try {
      await widget.apiService.updateLoan(
        widget.loan['id'].toString(),
        const <String, dynamic>{},
        borrowerName: borrower,
        principal: principal,
        interestRate: rateFraction,
        interestType: _interestType,
        // Empty clears the note (COALESCE keeps the old value only on
        // null; we send an explicit empty string to allow clearing).
        notes: notes,
        expectedRepaymentDate: _expectedRepaymentDate,
      );
      if (!mounted) return;
      // Hand the edited values back in the loan's display shape so the
      // detail sheet can update its header optimistically.
      Navigator.pop(context, <String, dynamic>{
        'borrower_name': borrower,
        'principal': principal,
        'interest_rate': rateFraction,
        'interest_type': _interestType,
        'notes': notes,
        if (_expectedRepaymentDate != null)
          'expected_repayment_date':
              DateFormat('yyyy-MM-dd').format(_expectedRepaymentDate!),
      });
    } on LoanTermsLockedException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(AppLocalizations.of(context).lendToastCouldntSaveChanges);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// =====================================================================
// Loan detail sheet — reconcile disbursement + repayments
// =====================================================================

class _LoanDetailSheet extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> loan;
  /// Called after each successful in-sheet mutation so the parent can
  /// refresh the loan list + the dashboard's cash-flow view live.
  final VoidCallback onMutated;
  /// Jump to a linked payment's bank transaction (closes this sheet first).
  final void Function(String txId, String description)? onOpenTransaction;

  const _LoanDetailSheet({
    required this.apiService,
    required this.loan,
    required this.onMutated,
    this.onOpenTransaction,
  });

  @override
  State<_LoanDetailSheet> createState() => _LoanDetailSheetState();
}

class _LoanDetailSheetState extends State<_LoanDetailSheet> {
  List<dynamic> _payments = [];
  List<dynamic> _disbSuggestions = [];
  List<dynamic> _repaySuggestions = [];
  bool _loading = true;
  // Phones collapse the amortization table behind a tap so the schedule
  // controls + due-date stay visible without a wall of rows. Short
  // schedules (≤3 rows) are treated as expanded — see _buildScheduleSection.
  bool _scheduleExpanded = false;

  String get _loanId => widget.loan['id'].toString();
  String get _currency => (widget.loan['currency'] ?? 'USD').toString();
  bool get _hasDisbursement => widget.loan['disbursement_tx_id'] != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final payments = await widget.apiService.getLoanPayments(_loanId);
      // Only fetch the suggestions the user can act on.
      final disb = _hasDisbursement
          ? <dynamic>[]
          : await widget.apiService
              .getLoanSuggestions(_loanId, 'disbursement')
              .catchError((_) => <dynamic>[]);
      final repay = await widget.apiService
          .getLoanSuggestions(_loanId, 'repayment')
          .catchError((_) => <dynamic>[]);
      if (!mounted) return;
      setState(() {
        _payments = payments;
        _disbSuggestions = disb;
        _repaySuggestions = repay;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _money(num v) => moneyFormat(_currency).format(v);

  /// Display variant of [_money] for headline figures (principal, total
  /// owed, interest earned/accrued, amount remaining): cents drop at the
  /// whole-money threshold. Schedule rows, payment history, and the
  /// transaction picker keep the exact [_money] — those are reconciled
  /// line by line.
  String _moneyDisplay(num v) => moneyFormat(_currency).displayMoney(v);

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    final gap = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (ctx, scroll) {
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {},
          child: ListView(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 32),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                (widget.loan['borrower_name'] ?? '').toString(),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                AppLocalizations.of(context).lendLentOutstandingMeta(
                    _moneyDisplay((widget.loan['principal'] as num?) ?? 0),
                    _moneyDisplay(_totalOwedRemaining())),
                style: TextStyle(fontSize: 13, color: context.textSubtle),
              ),
              const SizedBox(height: 20),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                _buildDisbursementSection(),
                SizedBox(height: gap),
                if (_buildInterestSection() case final w?) ...[
                  w,
                  SizedBox(height: gap),
                ],
                _buildScheduleSection(),
                SizedBox(height: gap),
                _buildRepaymentsSection(),
                SizedBox(height: gap),
                _buildStatusActions(),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: context.textPrimary)),
      );

  Widget _buildDisbursementSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppLocalizations.of(context).lendSectionDisbursement),
        if (_hasDisbursement)
          Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: context.positive),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context).lendDisbursementLinked,
                  style: TextStyle(fontSize: 13, color: context.textMuted)),
            ],
          )
        else ...[
          if (_disbSuggestions.isEmpty)
            Text(
              AppLocalizations.of(context).lendNoMatchingOutflow,
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            )
          else ...[
            Text(AppLocalizations.of(context).lendWhichTxFunded,
                style: TextStyle(fontSize: 12, color: context.textSubtle)),
            const SizedBox(height: 8),
            ..._disbSuggestions.map((s) => _suggestionTile(
                  s as Map<String, dynamic>,
                  onConfirm: () => _confirmDisbursement(s),
                )),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _openLinkDisbursement,
              icon: const Icon(Icons.link, size: 16),
              label: Text(AppLocalizations.of(context).lendLinkATransaction,
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openLinkDisbursement() async {
    final linked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _RecordPaymentSheet(
        apiService: widget.apiService,
        loanId: _loanId,
        currency: _currency,
        mode: _RecordMode.disbursement,
      ),
    );
    if (linked == true) {
      widget.loan['disbursement_tx_id'] = 'linked';
      await _load();
      widget.onMutated();
    }
  }

  /// Interest summary: realized (cash-basis) income plus the backend's
  /// informational "accrued but not yet paid" figure. Returns null —
  /// hiding the whole section — when there's nothing to show: no interest
  /// at all, or a terminal-status loan where accrued is meaningless.
  Widget? _buildInterestSection() {
    final status = (widget.loan['status'] ?? 'active').toString();
    final earned = (widget.loan['interest_earned'] as num?)?.toDouble() ?? 0;
    // Display the backend's accrued figure verbatim; never recompute it.
    // It's already zeroed server-side for terminal statuses, but gate here
    // too so a paid_off loan never shows an "owed" amount.
    final terminal =
        status == 'paid_off' || status == 'cancelled' || status == 'written_off';
    final accrued = terminal
        ? 0.0
        : (widget.loan['interest_accrued'] as num?)?.toDouble() ?? 0;
    if (earned <= 0 && accrued <= 0) return null;

    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l10n.lendingInterest),
        Row(
          children: [
            Icon(Icons.percent, size: 16, color: context.positive),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(fontSize: 13, color: context.textMuted),
                  children: [
                    TextSpan(text: '${l10n.lendingInterestEarnedLabel}: '),
                    TextSpan(
                      text: _moneyDisplay(earned),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: context.positive,
                      ),
                    ),
                    if (accrued > 0) ...[
                      const TextSpan(text: ' · '),
                      TextSpan(text: '${l10n.lendingAccruedNotYetPaid}: '),
                      TextSpan(
                        text: _moneyDisplay(accrued),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.warning,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRepaymentsSection() {
    // `_payments` includes scheduled installments (paid_amount == null), which
    // must NOT render here: they showed as "$0.00" rows whose Unlink button
    // deleted the schedule row and silently gapped the amortization table.
    // Only rows with an actual paid amount are real repayments.
    final reconciled = _payments
        .where((p) => (p as Map)['paid_amount'] != null)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(AppLocalizations.of(context).lendSectionRepayments),
        if (reconciled.isEmpty)
          Text(AppLocalizations.of(context).lendNoneRecordedYet,
              style: TextStyle(fontSize: 12, color: context.textSubtle))
        else
          ...reconciled.map((p) {
            final m = p as Map<String, dynamic>;
            // OFF-BANK: recorded amount but no real bank tx attached yet.
            final isOffBank =
                m['actual_tx_id'] == null && m['paid_amount'] != null;
            return isOffBank ? _offBankPaymentRow(m) : _linkedPaymentCard(m);
          }),
        const SizedBox(height: 12),
        if (_repaySuggestions.isNotEmpty) ...[
          Text(AppLocalizations.of(context).lendSuggestedRepayments,
              style: TextStyle(fontSize: 12, color: context.textSubtle)),
          const SizedBox(height: 8),
          ..._repaySuggestions.map((s) => _suggestionTile(
                s as Map<String, dynamic>,
                onConfirm: () => _confirmRepayment(s),
              )),
          const SizedBox(height: 8),
        ],
        // Always offer an explicit way to record a payment — pick any
        // bank inflow, or enter a cash/off-bank payment — independent of
        // whether the matcher suggested anything.
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _openRecordPayment,
            icon: const Icon(Icons.add, size: 16),
            label: Text(AppLocalizations.of(context).lendRecordAPayment,
                style: const TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  /// A linked repayment: a rich, tappable card that jumps to the bank
  /// transaction (merchant · account · category · amount).
  Widget _linkedPaymentCard(Map<String, dynamic> m) {
    final l = AppLocalizations.of(context);
    final title = (m['merchant_name'] ??
            m['tx_description'] ??
            l.lendLinkedPaymentUntitled)
        .toString();
    final amount = (m['paid_amount'] as num?) ?? 0;
    final account = (m['account_name'] ?? '').toString();
    final category = (m['category'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _openLinkedTx(m),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.tint(0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.south_west, size: 18, color: context.positive),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary)),
                    const SizedBox(height: 2),
                    Text('${_fmtPaidDate(m['paid_date'])} · ${_money(amount)}',
                        style: TextStyle(
                            fontSize: 12, color: context.textSubtle)),
                    if (account.isNotEmpty || category.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 10, runSpacing: 4, children: [
                        if (account.isNotEmpty)
                          _metaChip(
                              Icons.account_balance_wallet_outlined, account),
                        if (category.isNotEmpty)
                          _metaChip(Icons.sell_outlined, category),
                      ]),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.open_in_new, size: 16, color: context.textSubtle),
              IconButton(
                icon: const Icon(Icons.link_off, size: 16),
                tooltip: l.lendTooltipUnlink,
                onPressed: () => _unreconcile(m['id'].toString()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// An off-bank (cash / manually recorded) repayment: no transaction to
  /// open, but offer to attach a bank inflow so it's excluded from cash flow.
  Widget _offBankPaymentRow(Map<String, dynamic> m) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.payments_outlined, size: 16, color: context.textSubtle),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_fmtPaidDate(m['paid_date'])} · ${_money((m['paid_amount'] as num?) ?? 0)}',
                  style: TextStyle(fontSize: 13, color: context.textMuted),
                ),
                Text(l.lendOffBankBadge,
                    style: TextStyle(fontSize: 11, color: context.textFaint)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_link, size: 16),
            tooltip: l.lendLinkBankTx,
            onPressed: () => _openLinkBankTx(m['id'].toString()),
          ),
          IconButton(
            icon: const Icon(Icons.link_off, size: 16),
            tooltip: l.lendTooltipUnlink,
            onPressed: () => _unreconcile(m['id'].toString()),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: context.textFaint),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontSize: 11, color: context.textSubtle)),
      ],
    );
  }

  String _fmtPaidDate(dynamic isoDate) {
    final s = (isoDate ?? '').toString();
    if (s.isEmpty) return '';
    final parsed = DateTime.tryParse(s);
    return parsed == null ? s : DateFormat('MMM d, y').format(parsed);
  }

  /// Close the loan sheet, then jump to the linked bank transaction (the
  /// Transactions tab sits behind the sheet).
  void _openLinkedTx(Map<String, dynamic> m) {
    final txId = m['actual_tx_id']?.toString();
    if (txId == null || widget.onOpenTransaction == null) return;
    final label =
        (m['merchant_name'] ?? m['tx_description'] ?? '').toString();
    Navigator.of(context).pop();
    widget.onOpenTransaction!(txId, label);
  }

  Future<void> _openRecordPayment() async {
    final recorded = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _RecordPaymentSheet(
        apiService: widget.apiService,
        loanId: _loanId,
        currency: _currency,
        // Designate an inflow for repayment, or a cash payment.
        mode: _RecordMode.repayment,
      ),
    );
    if (recorded == true) {
      await _load();
      widget.onMutated();
    }
  }

  Widget _suggestionTile(Map<String, dynamic> s,
      {required VoidCallback onConfirm}) {
    final l = AppLocalizations.of(context);
    final conf = (s['confidence'] as num?)?.toInt() ?? 0;
    final amount = (s['amount'] as num?)?.toDouble() ?? 0;
    final account = (s['account_name'] ?? '').toString();
    final nameMatched = s['name_matched'] == true;
    // Tiered WORDS, not a raw "50% match" (which reads as half-wrong even
    // when it's the right transaction). Blue for the middle band is
    // neutral-informative rather than warning-amber.
    final (matchLabel, color) = conf >= 80
        ? (l.lendMatchStrong, context.positive)
        : conf >= 65
            ? (l.lendMatchLikely, context.info)
            : (l.lendMatchPossible, context.warning);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.tint(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (s['description'] ?? '').toString(),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${_fmtPaidDate(s['date'])} · ${_money(amount.abs())}',
                      style:
                          TextStyle(fontSize: 11, color: context.textSubtle),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: context.accentSoft(color),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(matchLabel,
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: color)),
                    ),
                    // The single strongest "trust this pick" signal — why a
                    // low-amount-confidence tx is still the right one.
                    if (nameMatched)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.person, size: 11, color: context.positive),
                        const SizedBox(width: 2),
                        Text(l.lendMatchNameHit,
                            style: TextStyle(
                                fontSize: 10, color: context.positive)),
                      ]),
                    if (account.isNotEmpty)
                      _metaChip(Icons.account_balance_wallet_outlined, account),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
              onPressed: onConfirm,
              child: Text(AppLocalizations.of(context).lendConfirm)),
        ],
      ),
    );
  }

  /// Amortization schedule: the generated installments with their
  /// principal/interest split. Distinguished from the Repayments
  /// section (which is about reconciliation) — this is the PLAN.
  Widget _buildScheduleSection() {
    // Scheduled rows = GENERATED installments, as opposed to
    // manually-recorded MVP repayments (which carry NO scheduled split —
    // both scheduled_principal and scheduled_interest are 0). Keep any
    // row that has a principal OR interest split: interest-only loans
    // emit scheduled_principal = 0 for every period except the final
    // balloon, so filtering on principal>0 alone collapses a 6-month
    // interest-only plan to a single row. Compound / lump_sum schedules
    // are genuinely a single row and stay that way (their one row has
    // both splits > 0).
    // Scheduled installments: any row carrying a planned amount (principal,
    // interest, OR a total scheduled_amount — a 0%/custom loan's rows have
    // scheduled_interest == 0 but a non-zero scheduled_amount).
    final scheduled = _payments.where((p) {
      final m = p as Map;
      final sp = (m['scheduled_principal'] as num?)?.toDouble() ?? 0;
      final si = (m['scheduled_interest'] as num?)?.toDouble() ?? 0;
      final sa = (m['scheduled_amount'] as num?)?.toDouble() ?? 0;
      return sp > 0 || si > 0 || sa > 0;
    }).toList();
    final l10n = AppLocalizations.of(context);
    // Whether interest is ever charged — drives whether to keep the
    // interest columns. 0%/custom loans hide them entirely.
    final hasInterest = scheduled.any((p) =>
        ((p as Map)['scheduled_interest'] as num?)?.toDouble() != null &&
        ((p['scheduled_interest'] as num?)?.toDouble() ?? 0) > 0.005);
    final hasTerms = widget.loan['term_months'] != null &&
        widget.loan['payment_frequency'] != null;
    // Custom loans carry an explicit schedule but no term/frequency; still
    // offer export + copy whenever there's actually a schedule to export.
    final canExport = hasTerms || scheduled.isNotEmpty;
    final phone = MediaQuery.sizeOf(context).width < 720;
    final shortSchedule = scheduled.length <= 3;
    final showTable = !phone || shortSchedule || _scheduleExpanded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: _sectionTitle(
                    AppLocalizations.of(context).lendSectionPaymentSchedule)),
            // Hand the borrower their plan: a printable one-pager, a CSV
            // that opens in Google Sheets / Excel, or a one-click "copy the
            // rows and open a fresh sheet".
            if (canExport)
              PopupMenuButton<String>(
                tooltip:
                    AppLocalizations.of(context).lendTooltipExportPaymentPlan,
                icon: const Icon(Icons.ios_share, size: 18),
                onSelected: (which) {
                  if (which == 'copySheets') {
                    _copyScheduleForSheets(scheduled);
                    return;
                  }
                  final url = which == 'csv'
                      ? widget.apiService.loanScheduleCsvUrl(_loanId)
                      : widget.apiService.loanPaymentPlanUrl(_loanId);
                  launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'plan',
                    child: Text(l10n.lendExportPrintablePlan),
                  ),
                  PopupMenuItem(
                    value: 'csv',
                    child: Text(l10n.lendExportDownloadCsv),
                  ),
                  PopupMenuItem(
                    value: 'copySheets',
                    child: Text(l10n.lendCopyForSheets),
                  ),
                ],
              ),
            if (hasTerms)
              TextButton.icon(
                onPressed: _generateSchedule,
                icon: Icon(scheduled.isEmpty ? Icons.add_chart : Icons.refresh,
                    size: 16),
                label: Text(
                    scheduled.isEmpty
                        ? l10n.lendScheduleGenerate
                        : l10n.lendScheduleRegenerate,
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
        if (scheduled.isEmpty)
          Text(
            hasTerms
                ? l10n.lendScheduleEmptyHasTerms
                : l10n.lendScheduleEmptyNoTerms,
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          )
        else ...[
          _buildScheduleProgress(scheduled),
          const SizedBox(height: 12),
          // Phones with a longer schedule collapse the table behind a
          // count-aware tap; short plans (≤3 rows) and wide screens show it.
          if (phone && !shortSchedule)
            InkWell(
              onTap: () =>
                  setState(() => _scheduleExpanded = !_scheduleExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.receipt_long,
                        color: context.tealAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.lendViewInstallments(scheduled.length),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      _scheduleExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: context.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          if (showTable) ...[
            if (phone && !shortSchedule) const SizedBox(height: 8),
            _buildScheduleTable(scheduled, showInterest: hasInterest),
          ],
        ],
        _buildDueDateRow(),
      ],
    );
  }

  /// True when [m] is a paid installment (its status is 'paid').
  bool _rowPaid(Map m) => m['status'] == 'paid';

  /// Index of the earliest UNPAID installment in [rows] — the "next due"
  /// row to highlight. -1 when every row is paid.
  int _nextDueIndex(List<dynamic> rows) {
    for (var i = 0; i < rows.length; i++) {
      if (!_rowPaid(rows[i] as Map)) return i;
    }
    return -1;
  }

  /// Running principal balance remaining after installment [i]: principal
  /// minus the cumulative scheduled PRINCIPAL through that row. (The payments
  /// endpoint doesn't carry a per-row balance, so it's derived here.) Using
  /// scheduled_principal — not scheduled_amount — keeps this correct for
  /// interest-bearing schedules (amortized/simple), where the payment also
  /// covers interest; for a 0%/custom loan the two are identical.
  double _balanceAfter(List<dynamic> rows, int i) {
    final principal = (widget.loan['principal'] as num?)?.toDouble() ?? 0;
    var cumulative = 0.0;
    for (var j = 0; j <= i; j++) {
      cumulative +=
          ((rows[j] as Map)['scheduled_principal'] as num?)?.toDouble() ?? 0;
    }
    final bal = principal - cumulative;
    return bal.abs() < 0.005 ? 0 : bal;
  }

  /// What the borrower still owes IN TOTAL (principal + interest): the sum of
  /// the unpaid scheduled payments. Falls back to the loan's principal-based
  /// outstanding when there's no generated schedule.
  double _totalOwedRemaining() {
    final scheduled = _payments
        .where((p) => (p as Map)['scheduled_amount'] != null)
        .toList();
    if (scheduled.isEmpty) {
      return (widget.loan['outstanding'] as num?)?.toDouble() ??
          (widget.loan['principal'] as num?)?.toDouble() ??
          0;
    }
    return scheduled.where((p) => !_rowPaid(p as Map)).fold<double>(
        0, (a, p) => a + (((p as Map)['scheduled_amount'] as num?)?.toDouble() ?? 0));
  }

  /// "Paid X of N payments" + a progress bar of the total repaid and the
  /// amount remaining.
  Widget _buildScheduleProgress(List<dynamic> rows) {
    final l10n = AppLocalizations.of(context);
    final total = rows.length;
    final paid = rows.where((p) => _rowPaid(p as Map)).length;
    // Base the bar + "remaining" on the TOTAL owed (Σ scheduled payments =
    // principal + interest), not just principal — so a 14k + 2k loan reads
    // "16,000 remaining", matching the schedule total and the agreement.
    double schedAmount(dynamic p) =>
        ((p as Map)['scheduled_amount'] as num?)?.toDouble() ?? 0;
    final totalOwed = rows.fold<double>(0, (a, p) => a + schedAmount(p));
    final outstanding = rows
        .where((p) => !_rowPaid(p as Map))
        .fold<double>(0, (a, p) => a + schedAmount(p));
    final frac =
        totalOwed <= 0 ? 0.0 : ((totalOwed - outstanding) / totalOwed).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.lendSchedulePaidProgress(paid, total),
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary),
              ),
            ),
            Text(
              l10n.lendScheduleRemaining(_moneyDisplay(outstanding)),
              style: TextStyle(fontSize: 12, color: context.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: frac.toDouble(),
            minHeight: 6,
            backgroundColor: context.tint(0.06),
            valueColor: AlwaysStoppedAnimation(context.positive),
          ),
        ),
      ],
    );
  }

  /// Build the schedule as TSV, copy to the clipboard, open a fresh Google
  /// Sheet, and confirm — so the user can paste straight in with Ctrl/Cmd+V.
  Future<void> _copyScheduleForSheets(List<dynamic> rows) async {
    final l10n = AppLocalizations.of(context);
    final buf = StringBuffer();
    buf.writeln('#\tDue date\tPayment\tBalance remaining\tStatus');
    for (var i = 0; i < rows.length; i++) {
      final m = rows[i] as Map<String, dynamic>;
      final amt = (m['scheduled_amount'] as num?)?.toDouble() ?? 0;
      final bal = _balanceAfter(rows, i);
      buf.writeln('${m['installment_number']}\t${m['due_date'] ?? ''}\t'
          '${amt.toStringAsFixed(2)}\t${bal.toStringAsFixed(2)}\t'
          '${(m['status'] ?? '').toString()}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    await launchUrl(Uri.parse('https://sheets.new'),
        webOnlyWindowName: '_blank');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.lendCopiedForSheets)));
  }

  // "Pay back by <date> · in N days / overdue" — the schedule-less due date.
  // Colour-coded: green when comfortably ahead, amber within a week, red when
  // overdue. Hidden when no expected_repayment_date is set.
  Widget _buildDueDateRow() {
    final raw = widget.loan['expected_repayment_date'];
    if (raw == null) return const SizedBox.shrink();
    final date = DateTime.tryParse(raw.toString());
    if (date == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final days = DateTime(date.year, date.month, date.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final overdue = days < 0;
    final color = overdue
        ? context.negative
        : (days <= 7 ? context.warning : context.positive);
    final l10n = AppLocalizations.of(context);
    final when = overdue
        ? l10n.lendingGlanceOverdueBy(-days)
        : (days == 0
            ? l10n.lendingGlanceDueToday
            : l10n.lendingAgingDaysUntil(days));
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(Icons.event_available_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.lendPayBackByWhen(
                  DateFormat('MMM d, y').format(date), when),
              style: TextStyle(
                  fontSize: 12.5, color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleTable(List<dynamic> rows, {bool showInterest = true}) {
    final l10n = AppLocalizations.of(context);
    final nextDue = _nextDueIndex(rows);
    // On a phone there's no room for 5-6 columns — the money truncates and
    // the Interest/Balance columns collide. Drop those two on narrow (the
    // Balance-remaining already shows in the progress line above); each row
    // instead carries a compact "int · balance" subtitle so nothing is lost.
    final narrow = MediaQuery.sizeOf(context).width < 520;
    // Totals footer.
    var totalPayment = 0.0;
    for (final p in rows) {
      totalPayment += ((p as Map)['scheduled_amount'] as num?)?.toDouble() ?? 0;
    }
    return Column(
      children: [
        // Header. For a 0%/custom loan the interest column is dropped and
        // we show the running Balance remaining instead of principal split.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              _schCell('#', flex: 1),
              _schCell(l10n.lendScheduleColDue, flex: 3),
              _schCell(l10n.lendScheduleColPayment, flex: 3, alignRight: true),
              if (showInterest && !narrow)
                _schCell(l10n.lendScheduleColInterest, flex: 3, alignRight: true),
              if (!narrow)
                _schCell(l10n.lendScheduleColBalance, flex: 3, alignRight: true),
              _schCell('', flex: 1, alignRight: true),
            ],
          ),
        ),
        Divider(height: 1, color: context.hairline),
        for (var i = 0; i < rows.length; i++) _scheduleRow(rows, i,
            showInterest: showInterest, isNextDue: i == nextDue, narrow: narrow),
        Divider(height: 1, color: context.hairline),
        // Totals footer.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Text(l10n.lendScheduleTotals,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary)),
              ),
              _schCell(_money(totalPayment),
                  flex: 3, alignRight: true, bold: true),
              if (showInterest && !narrow) _schCell('', flex: 3, alignRight: true),
              if (!narrow) _schCell('', flex: 3, alignRight: true),
              _schCell('', flex: 1, alignRight: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _scheduleRow(List<dynamic> rows, int i,
      {required bool showInterest,
      required bool isNextDue,
      required bool narrow}) {
    final m = rows[i] as Map<String, dynamic>;
    final l10n = AppLocalizations.of(context);
    final paid = _rowPaid(m);
    final payment = (m['scheduled_amount'] as num?)?.toDouble() ?? 0;
    final interest = (m['scheduled_interest'] as num?)?.toDouble() ?? 0;
    final balance = _balanceAfter(rows, i);
    return Container(
      decoration: isNextDue
          ? BoxDecoration(
              color: context.accentSoft(context.tealAccent),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      margin: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _schCell('${m['installment_number']}', flex: 1),
          // Due, with the dropped Interest/Balance folded into a subtitle on
          // narrow so no data is lost.
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_fmtDue(m['due_date']),
                    style: TextStyle(fontSize: 12, color: context.textMuted)),
                if (narrow)
                  Text(
                    l10n.lendScheduleRowMeta(
                        _money(balance), _money(interest)),
                    style:
                        TextStyle(fontSize: 10.5, color: context.textFaint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          _schCell(_money(payment), flex: 3, alignRight: true),
          if (showInterest && !narrow)
            _schCell(_money(interest), flex: 3, alignRight: true),
          if (!narrow)
            _schCell(_money(balance), flex: 3, alignRight: true),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerRight,
              child: Icon(
                paid ? Icons.check_circle : Icons.circle_outlined,
                size: 15,
                color: paid ? context.positive : context.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Short "MMM d" for the schedule's Due column — recovers width for the
  /// money columns vs. the raw ISO date. Falls back to the raw string when
  /// it doesn't parse.
  String _fmtDue(dynamic raw) {
    final s = (raw ?? '').toString();
    final d = DateTime.tryParse(s);
    return d == null ? s : DateFormat('MMM d').format(d);
  }

  Widget _schCell(String text,
      {int flex = 1, bool alignRight = false, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              color: bold ? context.textPrimary : context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// Loan actions — decluttered: the two everyday actions (Edit, Agreement)
  /// stay visible; the rarer lifecycle + destructive ones (pay off, mark
  /// defaulted, write off, reactivate, delete) fold into a "More" menu.
  Widget _buildStatusActions() {
    final l = AppLocalizations.of(context);
    final status = (widget.loan['status'] ?? 'active').toString();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: _openEditLoan,
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: Text(l.lendActionEdit, style: const TextStyle(fontSize: 12)),
        ),
        // Agreement — pick the language (a bilingual document).
        PopupMenuButton<String>(
          tooltip: l.lendActionAgreement,
          onSelected: (lang) => launchUrl(
              Uri.parse(widget.apiService.loanAgreementUrl(_loanId, lang: lang)),
              webOnlyWindowName: '_blank'),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'en', child: Text(l.lendAgreementEnglish)),
            PopupMenuItem(value: 'es', child: Text(l.lendAgreementSpanish)),
          ],
          child: _pseudoButton(Icons.description_outlined, l.lendActionAgreement),
        ),
        PopupMenuButton<String>(
          tooltip: l.lendActionMore,
          onSelected: _onMoreAction,
          itemBuilder: (_) => [
            if (status == 'active')
              PopupMenuItem(
                  value: 'payoff',
                  child: _menuRow(Icons.task_alt, l.lendActionPayOffInFull,
                      context.positive)),
            if (status != 'defaulted')
              PopupMenuItem(
                  value: 'defaulted',
                  child: _menuRow(Icons.warning_amber_outlined,
                      l.lendActionMarkDefaulted, null)),
            if (status != 'written_off')
              PopupMenuItem(
                  value: 'written_off',
                  child:
                      _menuRow(Icons.money_off, l.lendActionWriteOff, null)),
            if (status != 'active')
              PopupMenuItem(
                  value: 'active',
                  child: _menuRow(
                      Icons.restart_alt, l.lendActionReactivate, null)),
            const PopupMenuDivider(),
            PopupMenuItem(
                value: 'delete',
                child: _menuRow(
                    Icons.delete_outline, l.lendDeleteLoan, context.negative)),
          ],
          child: _pseudoButton(Icons.more_horiz, l.lendActionMore),
        ),
      ],
    );
  }

  /// A tappable widget styled like an OutlinedButton with a dropdown caret —
  /// used as a PopupMenuButton child so the menu opens on tap.
  Widget _pseudoButton(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        border: Border.all(color: context.hairline),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: context.textPrimary),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 12, color: context.textPrimary)),
        Icon(Icons.arrow_drop_down, size: 18, color: context.textSubtle),
      ]),
    );
  }

  Widget _menuRow(IconData icon, String label, Color? color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color ?? context.textSubtle),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(color: color)),
    ]);
  }

  void _onMoreAction(String value) {
    switch (value) {
      case 'payoff':
        _confirmPayoff();
      case 'delete':
        _confirmDelete();
      default:
        _setStatus(value); // 'defaulted' | 'written_off' | 'active'
    }
  }

  Future<void> _generateSchedule() async {
    final l10n = AppLocalizations.of(context);
    try {
      await widget.apiService.generateLoanSchedule(_loanId);
      await _load();
      widget.onMutated();
      _toast(l10n.lendToastScheduleGenerated);
    } catch (e) {
      // Server messages (409 reconciled / 422 open-ended) come through
      // the exception body.
      final msg = e.toString();
      _toast(msg.contains('reconciled')
          ? l10n.lendToastUnreconcileFirst
          : l10n.lendToastCouldntGenerateSchedule);
    }
  }

  Future<void> _openEditLoan() async {
    final l10n = AppLocalizations.of(context);
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _EditLoanDialog(
        apiService: widget.apiService,
        loan: widget.loan,
      ),
    );
    if (saved == null) return;
    // Reflect the edited fields locally so the sheet header updates
    // without waiting for the parent reload, then refresh both this
    // sheet (schedule may have been regenerated) and the dashboard.
    widget.loan.addAll(saved);
    await _load();
    widget.onMutated();
    if (mounted) setState(() {});
    _toast(l10n.lendToastLoanUpdated);
  }

  Future<void> _setStatus(String status) async {
    final l10n = AppLocalizations.of(context);
    try {
      await widget.apiService.updateLoan(_loanId, {'status': status});
      widget.loan['status'] = status;
      await _load();
      widget.onMutated();
      if (mounted) setState(() {});
    } catch (e) {
      _toast(l10n.lendToastCouldntUpdateStatus);
    }
  }

  Future<void> _confirmPayoff() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.lendPayoffConfirmTitle),
        content: Text(l10n.lendPayoffConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context).actionCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context).lendPayoffConfirmButton),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.apiService.payoffLoan(_loanId);
      widget.loan['status'] = 'paid_off';
      await _load();
      widget.onMutated();
      if (mounted) setState(() {});
      _toast(l10n.lendToastLoanPaidOff);
    } catch (e) {
      // 409 if the loan isn't active anymore (e.g. raced with another tab).
      _toast(e.toString().contains('not active')
          ? l10n.lendToastLoanNoLongerActive
          : l10n.lendToastCouldntPayOff);
    }
  }

  Future<void> _confirmDisbursement(Map<String, dynamic> s) async {
    final l10n = AppLocalizations.of(context);
    try {
      await widget.apiService
          .linkDisbursement(_loanId, s['transaction_id'].toString());
      // Mark linked locally so the section flips without a full reload.
      widget.loan['disbursement_tx_id'] = s['transaction_id'];
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast(l10n.lendToastCouldntLinkTx);
    }
  }

  Future<void> _confirmRepayment(Map<String, dynamic> s) async {
    final l10n = AppLocalizations.of(context);
    try {
      await widget.apiService.recordRepayment(_loanId,
          transactionId: s['transaction_id'].toString());
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast(l10n.lendToastCouldntRecordRepayment);
    }
  }

  Future<void> _unreconcile(String paymentId) async {
    final l10n = AppLocalizations.of(context);
    // unreconcile endpoint deletes the loan_payments row.
    try {
      await widget.apiService.deleteLoanPayment(paymentId);
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast(l10n.lendToastCouldntUnlink);
    }
  }

  /// Attach a real bank inflow to an OFF-BANK repayment (paid in cash /
  /// recorded before the statement landed). Presents the loan's repayment
  /// suggestions as candidates; picking one upgrades the existing
  /// installment in place (keeps its amount/split, sets the tx) so the
  /// deposit is excluded from cash flow without double-counting.
  Future<void> _openLinkBankTx(String paymentId) async {
    final l10n = AppLocalizations.of(context);
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 20,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.lendLinkBankTxTitle,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            if (_repaySuggestions.isEmpty)
              Text(l10n.lendLinkBankTxNone,
                  style: TextStyle(fontSize: 13, color: context.textSubtle))
            else
              ..._repaySuggestions.map((s) => _suggestionTile(
                    s as Map<String, dynamic>,
                    onConfirm: () =>
                        Navigator.of(sheetContext).pop(s),
                  )),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    try {
      await widget.apiService.attachTransactionToPayment(
        _loanId,
        paymentId,
        chosen['transaction_id'].toString(),
      );
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast(l10n.lendLinkBankTxError);
    }
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.lendDeleteLoanTitle),
        content: Text(l10n.lendDeleteLoanBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context).actionCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context).actionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.apiService.deleteLoan(_loanId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      _toast(l10n.lendToastCouldntDeleteLoan);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// =====================================================================
// Record-payment / link-transaction sheet
// =====================================================================

enum _RecordMode { repayment, disbursement }

/// A bottom sheet to either designate an existing bank transaction
/// (repayment inflow / disbursement outflow) or — for repayments —
/// record a cash/off-bank payment by amount + date.
///
/// Pops `true` when something was recorded so the caller can refresh.
class _RecordPaymentSheet extends StatefulWidget {
  final ApiService apiService;
  final String loanId;
  final String currency;
  final _RecordMode mode;

  const _RecordPaymentSheet({
    required this.apiService,
    required this.loanId,
    required this.currency,
    required this.mode,
  });

  @override
  State<_RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends State<_RecordPaymentSheet> {
  // Tab 0 = pick a bank transaction; tab 1 = cash (repayment only).
  int _tab = 0;
  List<dynamic> _txs = [];
  bool _loading = true;
  bool _submitting = false;
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();
  final _cashAmountCtrl = TextEditingController();
  DateTime _cashDate = DateTime.now();

  bool get _isRepayment => widget.mode == _RecordMode.repayment;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _cashAmountCtrl.dispose();
    super.dispose();
  }

  /// Fetch candidates server-side, scoped to the loan's currency and the
  /// correct sign (inflows for a repayment, outflows for a disbursement)
  /// and narrowed by the search box. Searching in SQL over the whole table
  /// — not a client-side filter over one recent page — is what lets the
  /// picker find a payment older than the newest N transactions.
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final txs = await widget.apiService.getTransactions(
        limit: 200,
        currency: widget.currency,
        sign: _isRepayment ? 'inflow' : 'outflow',
        query: _searchCtrl.text,
        // Don't offer a tx already reconciled to a loan — picking it would
        // only bounce with "already linked".
        excludeLinked: true,
      );
      if (!mounted) return;
      setState(() {
        _txs = txs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Debounced reload as the user types, so each keystroke doesn't fire a
  /// request. The search runs on the server (see [_load]).
  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _load);
  }

  String _money(num v) => moneyFormat(widget.currency).format(v);

  /// Candidate transactions. Sign (inflow vs outflow), currency, and the
  /// search query are all applied by the backend now (see [_load]), so this
  /// just adapts the loaded rows to the typed list the picker renders.
  List<Map<String, dynamic>> get _candidates =>
      _txs.whereType<Map<String, dynamic>>().toList();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = _isRepayment
        ? l10n.lendSheetRecordPayment
        : l10n.lendSheetLinkDisbursement;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (ctx, scroll) {
        return Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: context.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: context.textPrimary)),
                ],
              ),
            ),
            // Mode switch (cash is repayment-only).
            if (_isRepayment)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                        value: 0,
                        label: Text(
                            AppLocalizations.of(context).lendSegBankTransaction)),
                    ButtonSegment(
                        value: 1,
                        label: Text(AppLocalizations.of(context).lendSegCash)),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _tab == 1 && _isRepayment
                  ? _buildCashForm(scroll)
                  : _buildTxPicker(scroll),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTxPicker(ScrollController scroll) {
    final items = _candidates;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          // Kept mounted during (re)loads so a server-side search keeps
          // focus and doesn't flash the whole picker to a spinner.
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => _onSearchChanged(),
            decoration: InputDecoration(
              isDense: true,
              hintText: _isRepayment
                  ? AppLocalizations.of(context).lendSearchInflows
                  : AppLocalizations.of(context).lendSearchOutflows,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (items.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _isRepayment
                      ? AppLocalizations.of(context).lendNoIncomingTx
                      : AppLocalizations.of(context).lendNoOutgoingTx,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.textSubtle),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: items.length,
              itemBuilder: (_, i) {
                final t = items[i];
                final amt = (t['amount'] as num?)?.toDouble() ?? 0;
                return ListTile(
                  dense: true,
                  title: Text(
                    (t['description'] ?? t['merchant_name'] ?? 'Transaction')
                        .toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${t['date'] ?? ''} · ${_money(amt.abs())}'),
                  trailing: _submitting
                      ? null
                      : const Icon(Icons.add_circle_outline),
                  onTap: _submitting
                      ? null
                      : () => _submitTx(t['id'].toString()),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildCashForm(ScrollController scroll) {
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text(
          AppLocalizations.of(context).lendCashFormHint,
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _cashAmountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: AppLocalizations.of(context).lendFieldAmountReceived,
            prefixText: widget.currency == 'MXN' ? 'MXN ' : r'$ ',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: _pickCashDate,
          borderRadius: BorderRadius.circular(10),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).lendFieldReceivedOn,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(DateFormat('MMM d, y').format(_cashDate),
                style: TextStyle(color: context.textPrimary)),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _submitting ? null : _submitCash,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(AppLocalizations.of(context).lendToastRecordCashPayment),
        ),
      ],
    );
  }

  Future<void> _pickCashDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _cashDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _cashDate = picked);
  }

  Future<void> _submitTx(String txId) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _submitting = true);
    try {
      if (_isRepayment) {
        await widget.apiService.recordRepayment(widget.loanId,
            transactionId: txId);
      } else {
        await widget.apiService.linkDisbursement(widget.loanId, txId);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().contains('already')
              ? l10n.lendToastTxAlreadyLinked
              : l10n.lendToastCouldntRecordThat)));
    }
  }

  Future<void> _submitCash() async {
    final amount = double.tryParse(_cashAmountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppLocalizations.of(context).lendToastEnterValidAmount)));
      return;
    }
    setState(() => _submitting = true);
    try {
      final iso = DateFormat('yyyy-MM-dd').format(_cashDate);
      await widget.apiService
          .recordRepayment(widget.loanId, amount: amount, paidDate: iso);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppLocalizations.of(context).lendToastCouldntRecordCashPayment)));
    }
  }
}
