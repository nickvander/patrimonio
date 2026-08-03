import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart' show MoneyDisplayFormat, moneyFormat;
import '../utils/loan_dates.dart';
import '../utils/theme_colors.dart';
import 'edit_loan_dialog.dart';
import 'record_payment_sheet.dart';

/// Inner-width breakpoint for the payment-schedule table, measured against
/// the sheet's OWN `LayoutBuilder` constraint — never `MediaQuery` (skill
/// §4/§5). This is a modal bottom sheet: Material 3 caps it at 640dp wide
/// and centres it, so on a 1440dp window the screen width says "desktop"
/// while the table only ever gets ~590dp, and on a 700dp window the screen
/// says "phone" while the sheet is that same 640dp.
///
/// Below it the table can't hold its six columns (they collide and the money
/// truncates), so the Interest/Balance columns fold into a per-row subtitle
/// and a long schedule collapses behind a "view N installments" disclosure.
const double kScheduleNarrowWidth = 520.0;

class LoanDetailSheet extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> loan;

  /// Called after each successful in-sheet mutation so the parent can
  /// refresh the loan list + the dashboard's cash-flow view live.
  final VoidCallback onMutated;

  /// Jump to a linked payment's bank transaction (closes this sheet first).
  final void Function(String txId, String description)? onOpenTransaction;

  const LoanDetailSheet({
    super.key,
    required this.apiService,
    required this.loan,
    required this.onMutated,
    this.onOpenTransaction,
  });

  @override
  State<LoanDetailSheet> createState() => _LoanDetailSheetState();
}

class _LoanDetailSheetState extends State<LoanDetailSheet> {
  List<dynamic> _payments = [];
  List<dynamic> _disbSuggestions = [];
  List<dynamic> _repaySuggestions = [];
  bool _loading = true;
  // A sheet narrower than [kScheduleNarrowWidth] collapses the amortization
  // table behind a tap so the schedule controls + due-date stay visible
  // without a wall of rows. Short schedules (≤3 rows) are treated as
  // expanded — see _buildScheduleSection.
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
                  _moneyDisplay(_totalOwedRemaining()),
                ),
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
    child: Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: context.textPrimary,
      ),
    ),
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
              // Expanded, not a bare Text: the en string needs ~397dp and
              // overflowed this Row by 39px on a 390dp phone.
              Expanded(
                child: Text(
                  AppLocalizations.of(context).lendDisbursementLinked,
                  style: TextStyle(fontSize: 13, color: context.textMuted),
                ),
              ),
            ],
          )
        else ...[
          if (_disbSuggestions.isEmpty)
            Text(
              AppLocalizations.of(context).lendNoMatchingOutflow,
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            )
          else ...[
            Text(
              AppLocalizations.of(context).lendWhichTxFunded,
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            const SizedBox(height: 8),
            ..._disbSuggestions.map(
              (s) => _suggestionTile(
                s as Map<String, dynamic>,
                onConfirm: () => _confirmDisbursement(s),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _openLinkDisbursement,
              icon: const Icon(Icons.link, size: 16),
              label: Text(
                AppLocalizations.of(context).lendLinkATransaction,
                style: const TextStyle(fontSize: 12),
              ),
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
      builder: (_) => RecordPaymentSheet(
        apiService: widget.apiService,
        loanId: _loanId,
        currency: _currency,
        mode: RecordMode.disbursement,
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
        status == 'paid_off' ||
        status == 'cancelled' ||
        status == 'written_off';
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
          Text(
            AppLocalizations.of(context).lendNoneRecordedYet,
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          )
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
          Text(
            AppLocalizations.of(context).lendSuggestedRepayments,
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
          const SizedBox(height: 8),
          ..._repaySuggestions.map(
            (s) => _suggestionTile(
              s as Map<String, dynamic>,
              onConfirm: () => _confirmRepayment(s),
            ),
          ),
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
            label: Text(
              AppLocalizations.of(context).lendRecordAPayment,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  /// A linked repayment: a rich, tappable card that jumps to the bank
  /// transaction (merchant · account · category · amount).
  Widget _linkedPaymentCard(Map<String, dynamic> m) {
    final l = AppLocalizations.of(context);
    final title =
        (m['merchant_name'] ??
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
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmtPaidDate(m['paid_date'])} · ${_money(amount)}',
                      style: TextStyle(fontSize: 12, color: context.textSubtle),
                    ),
                    if (account.isNotEmpty || category.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          if (account.isNotEmpty)
                            _metaChip(
                              Icons.account_balance_wallet_outlined,
                              account,
                            ),
                          if (category.isNotEmpty)
                            _metaChip(Icons.sell_outlined, category),
                        ],
                      ),
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
                Text(
                  l.lendOffBankBadge,
                  style: TextStyle(fontSize: 11, color: context.textFaint),
                ),
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
        Text(text, style: TextStyle(fontSize: 11, color: context.textSubtle)),
      ],
    );
  }

  String _fmtPaidDate(dynamic isoDate) {
    final s = (isoDate ?? '').toString();
    if (s.isEmpty) return '';
    return formatIsoDateMedium(s);
  }

  /// Close the loan sheet, then jump to the linked bank transaction (the
  /// Transactions tab sits behind the sheet).
  void _openLinkedTx(Map<String, dynamic> m) {
    final txId = m['actual_tx_id']?.toString();
    if (txId == null || widget.onOpenTransaction == null) return;
    final label = (m['merchant_name'] ?? m['tx_description'] ?? '').toString();
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
      builder: (_) => RecordPaymentSheet(
        apiService: widget.apiService,
        loanId: _loanId,
        currency: _currency,
        // Designate an inflow for repayment, or a cash payment.
        mode: RecordMode.repayment,
      ),
    );
    if (recorded == true) {
      await _load();
      widget.onMutated();
    }
  }

  Widget _suggestionTile(
    Map<String, dynamic> s, {
    required VoidCallback onConfirm,
  }) {
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
                    color: context.textPrimary,
                  ),
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
                      style: TextStyle(fontSize: 11, color: context.textSubtle),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: context.accentSoft(color),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        matchLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ),
                    // The single strongest "trust this pick" signal — why a
                    // low-amount-confidence tx is still the right one.
                    if (nameMatched)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person, size: 11, color: context.positive),
                          const SizedBox(width: 2),
                          Text(
                            l.lendMatchNameHit,
                            style: TextStyle(
                              fontSize: 10,
                              color: context.positive,
                            ),
                          ),
                        ],
                      ),
                    if (account.isNotEmpty)
                      _metaChip(Icons.account_balance_wallet_outlined, account),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onConfirm,
            child: Text(AppLocalizations.of(context).lendConfirm),
          ),
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
    final hasInterest = scheduled.any(
      (p) =>
          ((p as Map)['scheduled_interest'] as num?)?.toDouble() != null &&
          ((p['scheduled_interest'] as num?)?.toDouble() ?? 0) > 0.005,
    );
    final hasTerms =
        widget.loan['term_months'] != null &&
        widget.loan['payment_frequency'] != null;
    // Custom loans carry an explicit schedule but no term/frequency; still
    // offer export + copy whenever there's actually a schedule to export.
    final canExport = hasTerms || scheduled.isNotEmpty;
    final shortSchedule = scheduled.length <= 3;

    // Both width branches (collapse the table behind a disclosure, and drop
    // the Interest/Balance columns) read the width the table ACTUALLY gets —
    // this sheet's inner constraint — not the window. See
    // [kScheduleNarrowWidth].
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < kScheduleNarrowWidth;
        final showTable = !narrow || shortSchedule || _scheduleExpanded;
        return _buildScheduleBody(
          scheduled: scheduled,
          l10n: l10n,
          hasInterest: hasInterest,
          hasTerms: hasTerms,
          canExport: canExport,
          narrow: narrow,
          shortSchedule: shortSchedule,
          showTable: showTable,
        );
      },
    );
  }

  /// The schedule section's content, once the width branches are resolved
  /// from the sheet's own constraint by [_buildScheduleSection].
  Widget _buildScheduleBody({
    required List<dynamic> scheduled,
    required AppLocalizations l10n,
    required bool hasInterest,
    required bool hasTerms,
    required bool canExport,
    required bool narrow,
    required bool shortSchedule,
    required bool showTable,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _sectionTitle(
                AppLocalizations.of(context).lendSectionPaymentSchedule,
              ),
            ),
            // Hand the borrower their plan: a printable one-pager, a CSV
            // that opens in Google Sheets / Excel, or a one-click "copy the
            // rows and open a fresh sheet".
            if (canExport)
              PopupMenuButton<String>(
                tooltip: AppLocalizations.of(
                  context,
                ).lendTooltipExportPaymentPlan,
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
                icon: Icon(
                  scheduled.isEmpty ? Icons.add_chart : Icons.refresh,
                  size: 16,
                ),
                label: Text(
                  scheduled.isEmpty
                      ? l10n.lendScheduleGenerate
                      : l10n.lendScheduleRegenerate,
                  style: const TextStyle(fontSize: 12),
                ),
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
          // A narrow sheet with a longer schedule collapses the table behind
          // a count-aware tap; short plans (≤3 rows) and sheets wide enough
          // for the full table show it inline.
          if (narrow && !shortSchedule)
            InkWell(
              onTap: () =>
                  setState(() => _scheduleExpanded = !_scheduleExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.receipt_long,
                      color: context.tealAccent,
                      size: 18,
                    ),
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
                      _scheduleExpanded ? Icons.expand_less : Icons.expand_more,
                      color: context.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          if (showTable) ...[
            if (narrow && !shortSchedule) const SizedBox(height: 8),
            _buildScheduleTable(
              scheduled,
              showInterest: hasInterest,
              narrow: narrow,
            ),
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
    return scheduled
        .where((p) => !_rowPaid(p as Map))
        .fold<double>(
          0,
          (a, p) =>
              a + (((p as Map)['scheduled_amount'] as num?)?.toDouble() ?? 0),
        );
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
    final frac = totalOwed <= 0
        ? 0.0
        : ((totalOwed - outstanding) / totalOwed).clamp(0.0, 1.0);
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
                  color: context.textPrimary,
                ),
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
      buf.writeln(
        '${m['installment_number']}\t${m['due_date'] ?? ''}\t'
        '${amt.toStringAsFixed(2)}\t${bal.toStringAsFixed(2)}\t'
        '${(m['status'] ?? '').toString()}',
      );
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    await launchUrl(
      Uri.parse('https://sheets.new'),
      webOnlyWindowName: '_blank',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.lendCopiedForSheets)));
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
    final days = DateTime(
      date.year,
      date.month,
      date.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
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
              // gen-l10n orders placeholders alphabetically (date, when) —
              // same as the template order here.
              l10n.lendPayBackByWhen(DateFormat.yMMMd().format(date), when),
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders the schedule. [narrow] — resolved by the caller from the
  /// sheet's own [LayoutBuilder] constraint, never the window — drops the
  /// Interest/Balance columns: below [kScheduleNarrowWidth] there's no room
  /// for 5-6 columns, the money truncates and those two collide. The amount
  /// remaining already shows in the progress line above, and each row
  /// carries a compact "int · balance" subtitle, so no data is lost.
  Widget _buildScheduleTable(
    List<dynamic> rows, {
    bool showInterest = true,
    required bool narrow,
  }) {
    final l10n = AppLocalizations.of(context);
    final nextDue = _nextDueIndex(rows);
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
                _schCell(
                  l10n.lendScheduleColInterest,
                  flex: 3,
                  alignRight: true,
                ),
              if (!narrow)
                _schCell(
                  l10n.lendScheduleColBalance,
                  flex: 3,
                  alignRight: true,
                ),
              _schCell('', flex: 1, alignRight: true),
            ],
          ),
        ),
        Divider(height: 1, color: context.hairline),
        for (var i = 0; i < rows.length; i++)
          _scheduleRow(
            rows,
            i,
            showInterest: showInterest,
            isNextDue: i == nextDue,
            narrow: narrow,
          ),
        Divider(height: 1, color: context.hairline),
        // Totals footer.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  l10n.lendScheduleTotals,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
              _schCell(
                _money(totalPayment),
                flex: 3,
                alignRight: true,
                bold: true,
              ),
              if (showInterest && !narrow)
                _schCell('', flex: 3, alignRight: true),
              if (!narrow) _schCell('', flex: 3, alignRight: true),
              _schCell('', flex: 1, alignRight: true),
            ],
          ),
        ),
        // Footnote for the "Principal balance" column (wide layouts only —
        // narrow drops the column): the running balance is principal, not
        // principal + interest, so say so where the space allows.
        if (!narrow)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.lendSchedulePrincipalBalanceNote,
                style: TextStyle(fontSize: 10.5, color: context.textFaint),
              ),
            ),
          ),
      ],
    );
  }

  Widget _scheduleRow(
    List<dynamic> rows,
    int i, {
    required bool showInterest,
    required bool isNextDue,
    required bool narrow,
  }) {
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
                Text(
                  _fmtDue(m['due_date']),
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
                if (narrow)
                  Text(
                    l10n.lendScheduleRowMeta(_money(balance), _money(interest)),
                    style: TextStyle(fontSize: 10.5, color: context.textFaint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          _schCell(_money(payment), flex: 3, alignRight: true),
          if (showInterest && !narrow)
            _schCell(_money(interest), flex: 3, alignRight: true),
          if (!narrow) _schCell(_money(balance), flex: 3, alignRight: true),
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

  /// Short locale-aware date for the schedule's Due column — recovers
  /// width for the money columns vs. the raw ISO date. Falls back to the
  /// raw string when it doesn't parse.
  String _fmtDue(dynamic raw) => formatIsoDateShort((raw ?? '').toString());

  Widget _schCell(
    String text, {
    int flex = 1,
    bool alignRight = false,
    bool bold = false,
  }) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            color: bold ? context.textPrimary : context.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
            webOnlyWindowName: '_blank',
          ),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'en', child: Text(l.lendAgreementEnglish)),
            PopupMenuItem(value: 'es', child: Text(l.lendAgreementSpanish)),
          ],
          child: _pseudoButton(
            Icons.description_outlined,
            l.lendActionAgreement,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: l.lendActionMore,
          onSelected: _onMoreAction,
          itemBuilder: (_) => [
            if (status == 'active')
              PopupMenuItem(
                value: 'payoff',
                child: _menuRow(
                  Icons.task_alt,
                  l.lendActionPayOffInFull,
                  context.positive,
                ),
              ),
            if (status != 'defaulted')
              PopupMenuItem(
                value: 'defaulted',
                child: _menuRow(
                  Icons.warning_amber_outlined,
                  l.lendActionMarkDefaulted,
                  null,
                ),
              ),
            if (status != 'written_off')
              PopupMenuItem(
                value: 'written_off',
                child: _menuRow(Icons.money_off, l.lendActionWriteOff, null),
              ),
            if (status != 'active')
              PopupMenuItem(
                value: 'active',
                child: _menuRow(
                  Icons.restart_alt,
                  l.lendActionReactivate,
                  null,
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'delete',
              child: _menuRow(
                Icons.delete_outline,
                l.lendDeleteLoan,
                context.negative,
              ),
            ),
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: context.textPrimary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: context.textPrimary),
          ),
          Icon(Icons.arrow_drop_down, size: 18, color: context.textSubtle),
        ],
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, Color? color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color ?? context.textSubtle),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
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
      _toast(
        msg.contains('reconciled')
            ? l10n.lendToastUnreconcileFirst
            : l10n.lendToastCouldntGenerateSchedule,
      );
    }
  }

  Future<void> _openEditLoan() async {
    final l10n = AppLocalizations.of(context);
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          EditLoanDialog(apiService: widget.apiService, loan: widget.loan),
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
            child: Text(AppLocalizations.of(context).actionCancel),
          ),
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
      _toast(
        e.toString().contains('not active')
            ? l10n.lendToastLoanNoLongerActive
            : l10n.lendToastCouldntPayOff,
      );
    }
  }

  Future<void> _confirmDisbursement(Map<String, dynamic> s) async {
    final l10n = AppLocalizations.of(context);
    try {
      await widget.apiService.linkDisbursement(
        _loanId,
        s['transaction_id'].toString(),
      );
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
      await widget.apiService.recordRepayment(
        _loanId,
        transactionId: s['transaction_id'].toString(),
      );
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
              Text(
                l10n.lendLinkBankTxNone,
                style: TextStyle(fontSize: 13, color: context.textSubtle),
              )
            else
              ..._repaySuggestions.map(
                (s) => _suggestionTile(
                  s as Map<String, dynamic>,
                  onConfirm: () => Navigator.of(sheetContext).pop(s),
                ),
              ),
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
            child: Text(AppLocalizations.of(context).actionCancel),
          ),
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
