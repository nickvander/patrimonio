import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:web/web.dart' as web;
import '../services/api_service.dart';
import '../utils/theme_colors.dart';

/// Personal lending tab — only mounted when the user enables the
/// module (app_settings 'lending_enabled'). Lists money the user has
/// lent, with auto-suggested reconciliation against real bank
/// transactions.
///
/// Self-contained: fetches its own loans + people + suggestions so the
/// dashboard doesn't have to thread loan state through. Calls
/// onChanged after any mutation so the dashboard can silently refresh
/// the cash-flow view (loan-linked transactions are excluded there).
class LendingTab extends StatefulWidget {
  final ApiService apiService;
  final String targetCurrency;
  final VoidCallback? onChanged;

  const LendingTab({
    super.key,
    required this.apiService,
    required this.targetCurrency,
    this.onChanged,
  });

  @override
  State<LendingTab> createState() => _LendingTabState();
}

class _LendingTabState extends State<LendingTab> {
  List<dynamic> _loans = [];
  List<dynamic> _people = [];
  Map<String, dynamic> _summary = {};
  // All-time interest-income report (total_interest + total_principal).
  Map<String, dynamic> _interestIncome = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.apiService.getLoans(),
        widget.apiService.getLoanPeople(),
        widget.apiService.getLoansSummary(),
        widget.apiService
            .getInterestIncome()
            .catchError((_) => <String, dynamic>{}),
      ]);
      if (!mounted) return;
      setState(() {
        _loans = results[0] as List<dynamic>;
        _people = results[1] as List<dynamic>;
        _summary = results[2] as Map<String, dynamic>;
        _interestIncome = results[3] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t load loans. Pull to retry.';
        _loading = false;
      });
    }
  }

  String _money(num v, String currency) {
    final fmt = NumberFormat.currency(
      symbol: currency == 'MXN' ? r'MX$' : r'$',
      decimalDigits: 2,
    );
    return fmt.format(v);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: context.textMuted)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          if (_loans.isEmpty)
            _buildEmptyState()
          else
            ..._loans.map((l) => _buildLoanCard(l as Map<String, dynamic>)),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final totalLent = (_summary['total_lent'] as num?)?.toDouble() ?? 0;
    final totalOut = (_summary['total_outstanding'] as num?)?.toDouble() ?? 0;
    final active = (_summary['active_count'] as num?)?.toInt() ?? 0;
    final interestEarned =
        (_interestIncome['total_interest'] as num?)?.toDouble() ?? 0;
    // Summary is denominated in each loan's own currency, summed
    // naively — fine for the common single-currency case. A mixed-
    // currency lender sees the caveat in the subtitle.
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.handshake_outlined, color: context.tealAccent),
                const SizedBox(width: 8),
                Text(
                  'Money I\'ve lent',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                const Spacer(),
                // Export the loan-interest CSV (cash-basis interest
                // income — hand to an accountant at tax time).
                if (interestEarned > 0)
                  IconButton(
                    tooltip: 'Export interest income (CSV)',
                    icon: const Icon(Icons.download_outlined),
                    onPressed: () => web.window.open(
                        widget.apiService.interestIncomeCsvUrl(), '_self'),
                  ),
                FilledButton.icon(
                  onPressed: _openAddLoanDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add loan'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _stat('Outstanding', _money(totalOut, 'USD'), context.warning),
                _stat('Total lent', _money(totalLent, 'USD'), context.textPrimary),
                _stat('Active', '$active', context.tealAccent),
                // Interest income — the headline of this feature.
                _stat('Interest earned', _money(interestEarned, 'USD'),
                    context.positive),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
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
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.handshake_outlined, size: 56, color: context.textFaint),
          const SizedBox(height: 12),
          Text('No loans yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: context.textMuted)),
          const SizedBox(height: 6),
          Text(
            'Lent money to a friend? Add it here, then designate the\n'
            'bank transactions that funded it and paid it back.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.textSubtle),
          ),
        ],
      ),
    );
  }

  Widget _buildLoanCard(Map<String, dynamic> loan) {
    final currency = (loan['currency'] ?? 'USD').toString();
    final outstanding = (loan['outstanding'] as num?)?.toDouble() ?? 0;
    final principal = (loan['principal'] as num?)?.toDouble() ?? 0;
    final repaid = (loan['total_repaid'] as num?)?.toDouble() ?? 0;
    final status = (loan['status'] ?? 'active').toString();
    final pct = principal > 0 ? (repaid / principal).clamp(0.0, 1.0) : 0.0;
    final linked = loan['disbursement_tx_id'] != null;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(top: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.hairline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openLoanDetail(loan),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (loan['borrower_name'] ?? 'Unknown').toString(),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  _statusPill(status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Lent ${_money(principal, currency)} · '
                '${(loan['origination_date'] ?? '').toString()}'
                '${linked ? '' : ' · disbursement not linked'}',
                style: TextStyle(fontSize: 12, color: context.textSubtle),
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
                  Text('Repaid ${_money(repaid, currency)}',
                      style: TextStyle(fontSize: 12, color: context.textMuted)),
                  Text('Outstanding ${_money(outstanding, currency)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: outstanding > 0
                            ? context.warning
                            : context.positive,
                      )),
                ],
              ),
              // Interest income realized on this loan, when any.
              if (((loan['interest_earned'] as num?)?.toDouble() ?? 0) > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Interest earned ${_money((loan['interest_earned'] as num).toDouble(), currency)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.positive,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill(String status) {
    final (label, color) = switch (status) {
      'paid_off' => ('Paid off', context.positive),
      'written_off' => ('Written off', context.negative),
      'cancelled' => ('Cancelled', context.textFaint),
      _ => ('Active', context.tealAccent),
    };
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

class _AddLoanDialog extends StatefulWidget {
  final ApiService apiService;
  final List<dynamic> people;
  final String defaultCurrency;

  const _AddLoanDialog({
    required this.apiService,
    required this.people,
    required this.defaultCurrency,
  });

  @override
  State<_AddLoanDialog> createState() => _AddLoanDialogState();
}

class _AddLoanDialogState extends State<_AddLoanDialog> {
  final _principalCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  final _termCtrl = TextEditingController();
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
  bool _submitting = false;

  /// Quick, clearly-labeled total-interest ESTIMATE for instant
  /// feedback as the user tunes the rate. Not authoritative — the
  /// exact penny-accurate schedule is generated server-side in Decimal.
  String? _rateEstimate() {
    final principal = double.tryParse(_principalCtrl.text.trim());
    final ratePct = double.tryParse(_rateCtrl.text.trim());
    final term = int.tryParse(_termCtrl.text.trim());
    if (principal == null || principal <= 0 || ratePct == null || ratePct <= 0) {
      return null;
    }
    // Normalize to an annual fraction.
    final annual = (_ratePeriod == 'monthly' ? ratePct * 12 : ratePct) / 100.0;
    final months = term ?? 12;
    final years = months / 12.0;
    final totalInterest = _interestType == 'interest_only'
        ? principal * annual * years // interest accrues on full balance
        : _interestType == 'simple'
            ? principal * annual * years
            : principal * annual * years * 0.55; // amortized ≈ half (declining)
    final cur = _currency == 'MXN' ? r'MX$' : r'$';
    return '≈ $cur${totalInterest.toStringAsFixed(0)} total interest over '
        '$months mo (estimate)';
  }

  @override
  void initState() {
    super.initState();
    _currency = widget.defaultCurrency == 'MXN' ? 'MXN' : 'USD';
  }

  @override
  void dispose() {
    _principalCtrl.dispose();
    _rateCtrl.dispose();
    _termCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peopleNames = widget.people
        .map((p) => (p as Map)['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();

    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: const Text('Add loan'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Borrower with autocomplete from the people directory.
            Autocomplete<String>(
              optionsBuilder: (value) {
                if (value.text.isEmpty) return peopleNames;
                return peopleNames.where((n) =>
                    n.toLowerCase().contains(value.text.toLowerCase()));
              },
              onSelected: (s) => _borrowerText = s,
              fieldViewBuilder: (ctx, ctrl, focus, _) {
                return TextField(
                  controller: ctrl,
                  focusNode: focus,
                  onChanged: (v) => _borrowerText = v,
                  decoration: const InputDecoration(
                    labelText: 'Borrower name',
                    hintText: 'e.g. Jose Ramirez',
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _principalCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount lent',
                prefixText: _currency == 'MXN' ? r'MX$ ' : r'$ ',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _currency,
                    decoration: const InputDecoration(labelText: 'Currency'),
                    items: const [
                      DropdownMenuItem(value: 'USD', child: Text('USD')),
                      DropdownMenuItem(value: 'MXN', child: Text('MXN')),
                    ],
                    onChanged: (v) => setState(() => _currency = v ?? 'USD'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration:
                          const InputDecoration(labelText: 'Lent on'),
                      child: Text(
                        DateFormat('MMM d, y').format(_originationDate),
                        style: TextStyle(color: context.textPrimary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _interestType,
              decoration: const InputDecoration(labelText: 'Interest'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('No interest')),
                DropdownMenuItem(
                    value: 'simple', child: Text('Simple interest')),
                DropdownMenuItem(
                    value: 'amortized', child: Text('Amortized (level payments)')),
                DropdownMenuItem(
                    value: 'interest_only',
                    child: Text('Interest-only (balloon)')),
              ],
              onChanged: (v) => setState(() => _interestType = v ?? 'none'),
            ),
            if (_interestType != 'none') ...[
              const SizedBox(height: 12),
              // Rate + per-year/per-month selector. The period is stored
              // faithfully, so "1 % / month" is amortized as exactly 1%
              // monthly — no lossy reconversion to an annual figure.
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _rateCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Rate %',
                        hintText: 'e.g. 5',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      initialValue: _ratePeriod,
                      decoration: const InputDecoration(labelText: 'per'),
                      items: const [
                        DropdownMenuItem(value: 'annual', child: Text('year')),
                        DropdownMenuItem(value: 'monthly', child: Text('month')),
                      ],
                      onChanged: (v) =>
                          setState(() => _ratePeriod = v ?? 'annual'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _termCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Term (months)',
                        hintText: 'e.g. 12',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: 'monthly',
                      decoration:
                          const InputDecoration(labelText: 'Payments'),
                      items: const [
                        DropdownMenuItem(
                            value: 'monthly', child: Text('Monthly')),
                        DropdownMenuItem(
                            value: 'weekly', child: Text('Weekly')),
                        DropdownMenuItem(
                            value: 'lump_sum', child: Text('Lump sum')),
                      ],
                      onChanged: (v) =>
                          setState(() => _paymentFrequency = v ?? 'monthly'),
                    ),
                  ),
                ],
              ),
              // Live, clearly-labeled estimate so the user gets instant
              // feedback as they tune the rate. Exact schedule is
              // generated server-side from the loan's detail view.
              if (_rateEstimate() != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _rateEstimate()!,
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
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

  Future<void> _submit() async {
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast('Enter a borrower name');
      return;
    }
    if (principal == null || principal <= 0) {
      _toast('Enter a valid amount');
      return;
    }
    setState(() => _submitting = true);
    try {
      // Rate entered as a percent; backend wants a fraction. The period
      // (year/month) is passed through verbatim so it's stored exactly.
      final ratePct = double.tryParse(_rateCtrl.text.trim()) ?? 0;
      final term = int.tryParse(_termCtrl.text.trim());
      final interestBearing = _interestType != 'none';
      await widget.apiService.createLoan(
        borrowerName: borrower,
        principal: principal,
        currency: _currency,
        originationDate: _originationDate,
        interestRate: interestBearing ? ratePct / 100.0 : 0,
        interestType: _interestType,
        ratePeriod: _ratePeriod,
        termMonths: interestBearing ? term : null,
        paymentFrequency: interestBearing ? _paymentFrequency : null,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast('Failed to add loan');
    }
  }

  void _toast(String msg) {
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

  const _LoanDetailSheet({
    required this.apiService,
    required this.loan,
    required this.onMutated,
  });

  @override
  State<_LoanDetailSheet> createState() => _LoanDetailSheetState();
}

class _LoanDetailSheetState extends State<_LoanDetailSheet> {
  List<dynamic> _payments = [];
  List<dynamic> _disbSuggestions = [];
  List<dynamic> _repaySuggestions = [];
  bool _loading = true;

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

  String _money(num v) {
    final fmt = NumberFormat.currency(
        symbol: _currency == 'MXN' ? r'MX$' : r'$', decimalDigits: 2);
    return fmt.format(v);
  }

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
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
                'Lent ${_money((widget.loan['principal'] as num?) ?? 0)} · '
                'outstanding ${_money((widget.loan['outstanding'] as num?) ?? 0)}',
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
                const SizedBox(height: 24),
                _buildScheduleSection(),
                const SizedBox(height: 24),
                _buildRepaymentsSection(),
                const SizedBox(height: 24),
                _buildStatusActions(),
                const SizedBox(height: 8),
                _buildDangerZone(),
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
        _sectionTitle('Disbursement'),
        if (_hasDisbursement)
          Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: context.positive),
              const SizedBox(width: 8),
              Text('Linked to a bank transaction',
                  style: TextStyle(fontSize: 13, color: context.textMuted)),
            ],
          )
        else if (_disbSuggestions.isEmpty)
          Text(
            'No matching outflow found near the loan date. You can link '
            'one manually from the Transactions tab later.',
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          )
        else ...[
          Text('Which transaction funded this loan?',
              style: TextStyle(fontSize: 12, color: context.textSubtle)),
          const SizedBox(height: 8),
          ..._disbSuggestions.map((s) => _suggestionTile(
                s as Map<String, dynamic>,
                onConfirm: () => _confirmDisbursement(s),
              )),
        ],
      ],
    );
  }

  Widget _buildRepaymentsSection() {
    final reconciled = _payments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Repayments'),
        if (reconciled.isEmpty)
          Text('None recorded yet.',
              style: TextStyle(fontSize: 12, color: context.textSubtle))
        else
          ...reconciled.map((p) {
            final m = p as Map<String, dynamic>;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.south_west, size: 16, color: context.positive),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${m['paid_date'] ?? ''} · ${_money((m['paid_amount'] as num?) ?? 0)}',
                      style:
                          TextStyle(fontSize: 13, color: context.textMuted),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link_off, size: 16),
                    tooltip: 'Unlink',
                    onPressed: () => _unreconcile(m['id'].toString()),
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 12),
        if (_repaySuggestions.isNotEmpty) ...[
          Text('Suggested repayments',
              style: TextStyle(fontSize: 12, color: context.textSubtle)),
          const SizedBox(height: 8),
          ..._repaySuggestions.map((s) => _suggestionTile(
                s as Map<String, dynamic>,
                onConfirm: () => _confirmRepayment(s),
              )),
        ],
      ],
    );
  }

  Widget _suggestionTile(Map<String, dynamic> s,
      {required VoidCallback onConfirm}) {
    final conf = (s['confidence'] as num?)?.toInt() ?? 0;
    final amount = (s['amount'] as num?)?.toDouble() ?? 0;
    final color = conf >= 80 ? context.positive : context.warning;
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
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '${s['date']} · ${_money(amount.abs())}',
                      style:
                          TextStyle(fontSize: 11, color: context.textSubtle),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: context.accentSoft(color),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('$conf% match',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: color)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(onPressed: onConfirm, child: const Text('Confirm')),
        ],
      ),
    );
  }

  /// Amortization schedule: the generated installments with their
  /// principal/interest split. Distinguished from the Repayments
  /// section (which is about reconciliation) — this is the PLAN.
  Widget _buildScheduleSection() {
    // Scheduled rows = those with a principal split (generated), as
    // opposed to manually-recorded MVP repayments (principal 0).
    final scheduled = _payments
        .where((p) => ((p as Map)['scheduled_principal'] as num? ?? 0) > 0)
        .toList();
    final hasTerms = widget.loan['term_months'] != null &&
        widget.loan['payment_frequency'] != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle('Payment schedule')),
            if (hasTerms)
              TextButton.icon(
                onPressed: _generateSchedule,
                icon: Icon(scheduled.isEmpty ? Icons.add_chart : Icons.refresh,
                    size: 16),
                label: Text(scheduled.isEmpty ? 'Generate' : 'Regenerate',
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
        if (scheduled.isEmpty)
          Text(
            hasTerms
                ? 'No schedule yet. Generate one to see the amortization '
                    'plan (principal + interest per installment).'
                : 'This loan has no term / payment frequency, so there\'s '
                    'no fixed schedule — record repayments as they come in.',
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          )
        else
          _buildScheduleTable(scheduled),
      ],
    );
  }

  Widget _buildScheduleTable(List<dynamic> rows) {
    return Column(
      children: [
        // Header.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              _schCell('#', flex: 1),
              _schCell('Due', flex: 3),
              _schCell('Principal', flex: 3, alignRight: true),
              _schCell('Interest', flex: 3, alignRight: true),
              _schCell('', flex: 2, alignRight: true),
            ],
          ),
        ),
        Divider(height: 1, color: context.hairline),
        ...rows.map((p) {
          final m = p as Map<String, dynamic>;
          final paid = (m['status'] == 'paid');
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                _schCell('${m['installment_number']}', flex: 1),
                _schCell((m['due_date'] ?? '').toString(), flex: 3),
                _schCell(_money((m['scheduled_principal'] as num?) ?? 0),
                    flex: 3, alignRight: true),
                _schCell(_money((m['scheduled_interest'] as num?) ?? 0),
                    flex: 3, alignRight: true),
                Expanded(
                  flex: 2,
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
        }),
      ],
    );
  }

  Widget _schCell(String text,
      {int flex = 1, bool alignRight = false}) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(text,
            style: TextStyle(
              fontSize: 12,
              color: context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// Status actions: mark defaulted / written-off / back to active.
  Widget _buildStatusActions() {
    final status = (widget.loan['status'] ?? 'active').toString();
    return Wrap(
      spacing: 8,
      children: [
        if (status != 'defaulted')
          OutlinedButton.icon(
            onPressed: () => _setStatus('defaulted'),
            icon: const Icon(Icons.warning_amber_outlined, size: 16),
            label: const Text('Mark defaulted', style: TextStyle(fontSize: 12)),
          ),
        if (status != 'written_off')
          OutlinedButton.icon(
            onPressed: () => _setStatus('written_off'),
            icon: const Icon(Icons.money_off, size: 16),
            label: const Text('Write off', style: TextStyle(fontSize: 12)),
          ),
        if (status != 'active')
          OutlinedButton.icon(
            onPressed: () => _setStatus('active'),
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('Reactivate', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }

  Future<void> _generateSchedule() async {
    try {
      await widget.apiService.generateLoanSchedule(_loanId);
      await _load();
      widget.onMutated();
      _toast('Schedule generated');
    } catch (e) {
      // Server messages (409 reconciled / 422 open-ended) come through
      // the exception body.
      final msg = e.toString();
      _toast(msg.contains('reconciled')
          ? 'Unreconcile payments first to regenerate'
          : 'Couldn\'t generate schedule');
    }
  }

  Future<void> _setStatus(String status) async {
    try {
      await widget.apiService.updateLoan(_loanId, {'status': status});
      widget.loan['status'] = status;
      await _load();
      widget.onMutated();
      if (mounted) setState(() {});
    } catch (e) {
      _toast('Couldn\'t update status');
    }
  }

  Widget _buildDangerZone() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _confirmDelete,
        icon: Icon(Icons.delete_outline, size: 18, color: context.negative),
        label: Text('Delete loan',
            style: TextStyle(color: context.negative)),
      ),
    );
  }

  Future<void> _confirmDisbursement(Map<String, dynamic> s) async {
    try {
      await widget.apiService
          .linkDisbursement(_loanId, s['transaction_id'].toString());
      // Mark linked locally so the section flips without a full reload.
      widget.loan['disbursement_tx_id'] = s['transaction_id'];
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast('Couldn\'t link that transaction');
    }
  }

  Future<void> _confirmRepayment(Map<String, dynamic> s) async {
    try {
      await widget.apiService
          .recordRepayment(_loanId, s['transaction_id'].toString());
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast('Couldn\'t record that repayment');
    }
  }

  Future<void> _unreconcile(String paymentId) async {
    // unreconcile endpoint deletes the loan_payments row.
    try {
      await widget.apiService.deleteLoanPayment(paymentId);
      await _load();
      widget.onMutated();
    } catch (e) {
      _toast('Couldn\'t unlink');
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete loan?'),
        content: const Text(
            'This removes the loan and its repayment records. The bank '
            'transactions themselves are not deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
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
      _toast('Couldn\'t delete loan');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
