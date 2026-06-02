import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/lending_summary.dart';
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
  /// USD→MXN spot rate, used to convert each loan from its native
  /// currency into [targetCurrency] for the summary totals. Defaults to
  /// 1.0 (no conversion) when the rate hasn't loaded.
  final double usdMxnRate;
  final VoidCallback? onChanged;

  const LendingTab({
    super.key,
    required this.apiService,
    required this.targetCurrency,
    this.usdMxnRate = 1.0,
    this.onChanged,
  });

  @override
  State<LendingTab> createState() => _LendingTabState();
}

class _LendingTabState extends State<LendingTab> {
  List<dynamic> _loans = [];
  List<dynamic> _people = [];
  Map<String, dynamic> _summary = {};
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
      ]);
      if (!mounted) return;
      setState(() {
        _loans = results[0] as List<dynamic>;
        _people = results[1] as List<dynamic>;
        _summary = results[2] as Map<String, dynamic>;
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
    // Anything whose magnitude rounds below half a cent is zero for display.
    // Without this, a negative zero (-0.0) or sub-cent residue formats as an
    // ugly "-$0.00" — e.g. the "Interest earned" stat with no payments yet.
    return fmt.format(v.abs() < 0.005 ? 0 : v);
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
    final totalOut = sumLoansConverted(
        _loans, 'outstanding', summaryCur, widget.usdMxnRate);
    final interestEarned = sumLoansConverted(
        _loans, 'interest_earned', summaryCur, widget.usdMxnRate);
    final active = (_summary['active_count'] as num?)?.toInt() ?? 0;
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
                Icon(Icons.monetization_on, color: context.tealAccent),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context).lendingTitle,
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
                  PopupMenuButton<String>(
                    tooltip: 'Export interest income',
                    icon: const Icon(Icons.download_outlined),
                    onSelected: (which) {
                      final url = which == 'summary'
                          ? widget.apiService.interestSummaryCsvUrl()
                          : widget.apiService.interestIncomeCsvUrl();
                      launchUrl(Uri.parse(url),
                          webOnlyWindowName: '_self');
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'detail',
                        child: Text('Interest payments (CSV)'),
                      ),
                      PopupMenuItem(
                        value: 'summary',
                        child: Text('Year-end summary by borrower (CSV)'),
                      ),
                    ],
                  ),
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
                  'Totals converted to $summaryCur at the current spot rate',
                  style: TextStyle(fontSize: 11, color: context.textSubtle),
                ),
              ),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _stat(AppLocalizations.of(context).lendingOutstanding,
                    _money(totalOut, summaryCur), context.warning),
                _stat(AppLocalizations.of(context).lendingTotalLent,
                    _money(totalLent, summaryCur), context.textPrimary),
                _stat(AppLocalizations.of(context).lendingActive, '$active',
                    context.tealAccent),
                // Interest income — the headline of this feature.
                _stat(AppLocalizations.of(context).lendingInterestEarned,
                    _money(interestEarned, summaryCur), context.positive),
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
              // Interest income realized on this loan, when any.
              if (((loan['interest_earned'] as num?)?.toDouble() ?? 0) > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${AppLocalizations.of(context).lendingInterestEarned} ${_money((loan['interest_earned'] as num).toDouble(), currency)}',
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
  bool _submitting = false;

  /// Native-currency symbol for the loan being entered (never the
  /// converted display currency — the preview always speaks the loan's
  /// own money).
  String get _sym => _currency == 'MXN' ? r'MX$' : r'$';

  /// Live, approximate projection of this loan's finances for the preview
  /// card. Mirrors the backend schedule formulas (see lending_summary
  /// `projectLoan`); the penny-accurate schedule is still generated
  /// server-side in Decimal once the loan is saved.
  LoanProjection? _projection() => projectLoan(
        principal: double.tryParse(_principalCtrl.text.trim()),
        interestType: _interestType,
        ratePercent: double.tryParse(_rateCtrl.text.trim()),
        ratePeriod: _ratePeriod,
        termMonths: int.tryParse(_termCtrl.text.trim()),
        paymentFrequency: _paymentFrequency,
      );

  String _fmtMoney(double v) {
    final f = NumberFormat.currency(symbol: '$_sym ', decimalDigits: 2);
    return f.format(v);
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
    _notesCtrl.dispose();
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
    // Height the scrollable content may take. AlertDialog stacks the
    // title (~88) + actions (~64) + inset padding (48) on top of the
    // content, plus any keyboard inset — leave room for all of it so the
    // dialog never runs off a short viewport. Floor keeps it usable on
    // very small screens (content scrolls within this box).
    final contentMaxHeight =
        (media.size.height - media.viewInsets.bottom - 220)
            .clamp(220.0, 620.0);

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
            child: Icon(Icons.monetization_on,
                color: context.tealAccent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add loan',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary)),
                Text('Record money you lent and track repayment',
                    style: TextStyle(fontSize: 12, color: context.textMuted)),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: contentMaxHeight,
        ),
        child: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section('Borrower & amount', [
                  Autocomplete<String>(
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
                      decoration: _decoration('Borrower name',
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
                    decoration: _decoration('Amount lent',
                        prefixText: '$_sym ',
                        icon: Icons.payments_outlined),
                  ),
                  const SizedBox(height: 12),
                  _twoUp(
                    narrow,
                    DropdownButtonFormField<String>(
                      initialValue: _currency,
                      isExpanded: true,
                      decoration: _decoration('Currency'),
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
                        decoration: _decoration('Lent on',
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
                _section('Interest terms', [
                  DropdownButtonFormField<String>(
                    initialValue: _interestType,
                    isExpanded: true,
                    decoration: _decoration('Interest type'),
                    items: const [
                      DropdownMenuItem(
                          value: 'none', child: Text('No interest')),
                      DropdownMenuItem(
                          value: 'simple', child: Text('Simple interest')),
                      DropdownMenuItem(
                          value: 'amortized', child: Text('Amortized')),
                      DropdownMenuItem(
                          value: 'interest_only',
                          child: Text('Interest-only')),
                      DropdownMenuItem(
                          value: 'compound', child: Text('Compound')),
                    ],
                    onChanged: (v) =>
                        setState(() => _interestType = v ?? 'none'),
                  ),
                  if (_interestType != 'none') ...[
                    const SizedBox(height: 12),
                    _twoUp(
                      narrow,
                      TextField(
                        controller: _rateCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: _decoration('Rate %',
                            hint: 'e.g. 5', icon: Icons.percent),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _ratePeriod,
                        isExpanded: true,
                        decoration: _decoration('per'),
                        items: const [
                          DropdownMenuItem(
                              value: 'annual', child: Text('year')),
                          DropdownMenuItem(
                              value: 'monthly', child: Text('month')),
                        ],
                        onChanged: (v) =>
                            setState(() => _ratePeriod = v ?? 'annual'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _twoUp(
                      narrow,
                      TextField(
                        controller: _termCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: _decoration('Term (months)',
                            hint: 'e.g. 12',
                            icon: Icons.schedule_outlined),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _paymentFrequency,
                        isExpanded: true,
                        decoration: _decoration('Payments'),
                        items: const [
                          DropdownMenuItem(
                              value: 'monthly', child: Text('Monthly')),
                          DropdownMenuItem(
                              value: 'weekly', child: Text('Weekly')),
                          DropdownMenuItem(
                              value: 'lump_sum', child: Text('Lump sum')),
                        ],
                        onChanged: (v) => setState(
                            () => _paymentFrequency = v ?? 'monthly'),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 16),
                _section('Notes', [
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 2,
                    decoration: _decoration('Optional',
                        hint: 'e.g. for the car deposit',
                        icon: Icons.notes_outlined),
                  ),
                ]),
                const SizedBox(height: 16),
                _buildPreviewCard(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add, size: 18),
          label: const Text('Add loan'),
        ),
      ],
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

  /// Always-visible projection so the user sees the finances before
  /// saving — including no-interest loans, where it shows the total to
  /// repay. Native currency only (never the converted display value).
  Widget _buildPreviewCard() {
    final proj = _projection();
    final accent = context.tealAccent;

    final List<Widget> rows;
    if (proj == null) {
      rows = [
        Text('Enter an amount to see the projection',
            style: TextStyle(fontSize: 13, color: context.textSubtle)),
      ];
    } else {
      final cadenceLabel = switch (proj.cadence) {
        'monthly' => '/mo',
        'weekly' => '/wk',
        _ => '',
      };
      rows = [
        _previewRow('Total to repay', _fmtMoney(proj.totalRepayment),
            bold: true),
        const SizedBox(height: 6),
        if (proj.totalInterest > 0.005)
          _previewRow('Projected interest', _fmtMoney(proj.totalInterest),
              color: accent)
        else
          Text('No interest on this loan',
              style: TextStyle(fontSize: 12, color: context.textMuted)),
        if (proj.perPayment != null) ...[
          const SizedBox(height: 6),
          _previewRow(
            proj.cadence == 'balloon' ? 'Single payment' : 'Payment',
            proj.cadence == 'balloon'
                ? _fmtMoney(proj.perPayment!)
                // Interest-only loans pay interest periodically, so label the
                // recurring figure as such — otherwise "$125/mo · 12 payments"
                // reads as the whole obligation when it's just the interest.
                : '${_fmtMoney(proj.perPayment!)}$cadenceLabel'
                    '${proj.balloonPayment != null ? ' interest' : ''}'
                    '${proj.periods != null ? '  ·  ${proj.periods} payments' : ''}',
          ),
          // Interest-only: the principal balloons on the final installment,
          // so the borrower's last payment is the interest PLUS this amount.
          if (proj.balloonPayment != null && proj.balloonPayment! > 0.005) ...[
            const SizedBox(height: 6),
            _previewRow(
              'Principal at maturity',
              '${_fmtMoney(proj.balloonPayment!)}  ·  due with final payment',
            ),
          ],
        ] else ...[
          const SizedBox(height: 6),
          Text('Open-ended — repay anytime, no fixed schedule',
              style: TextStyle(fontSize: 12, color: context.textSubtle)),
        ],
      ];
    }

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
              Text('Loan preview',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent)),
              const Spacer(),
              Text('estimate',
                  style: TextStyle(fontSize: 10, color: context.textSubtle)),
            ],
          ),
          const SizedBox(height: 10),
          ...rows,
        ],
      ),
    );
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
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
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
                Text('Edit loan',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary)),
                Text('Correct the borrower, amount, or interest terms',
                    style: TextStyle(fontSize: 12, color: context.textMuted)),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: contentMaxHeight,
        ),
        child: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section('Borrower & amount', [
                  TextField(
                    controller: _borrowerCtrl,
                    decoration: _decoration('Borrower name',
                        icon: Icons.person_outline),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _principalCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: _decoration('Amount lent',
                        prefixText: '$_sym ',
                        icon: Icons.payments_outlined),
                  ),
                ]),
                const SizedBox(height: 16),
                _section('Interest terms', [
                  DropdownButtonFormField<String>(
                    initialValue: _interestType,
                    isExpanded: true,
                    decoration: _decoration('Interest type'),
                    items: const [
                      DropdownMenuItem(
                          value: 'none', child: Text('No interest')),
                      DropdownMenuItem(
                          value: 'simple', child: Text('Simple interest')),
                      DropdownMenuItem(
                          value: 'amortized', child: Text('Amortized')),
                      DropdownMenuItem(
                          value: 'interest_only',
                          child: Text('Interest-only')),
                      DropdownMenuItem(
                          value: 'compound', child: Text('Compound')),
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
                          'Rate % per ${_ratePeriod == 'monthly' ? 'month' : 'year'}',
                          hint: 'e.g. 5',
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
                _section('Notes', [
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 2,
                    decoration: _decoration('Optional',
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
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check, size: 18),
          label: const Text('Save changes'),
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
    final parts = <String>[];
    if (term != null) parts.add('$term-month term');
    if (freq != null && freq.isNotEmpty) {
      parts.add(switch (freq) {
        'monthly' => 'monthly payments',
        'weekly' => 'weekly payments',
        'lump_sum' => 'single lump-sum payment',
        _ => '$freq payments',
      });
    }
    return 'Term & schedule (${parts.join(' · ')}) are fixed — '
        'delete and re-add to change them.';
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
      _toast('Enter a borrower name');
      return;
    }
    if (principal == null || principal <= 0) {
      _toast('Enter a valid amount');
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
      });
    } on LoanTermsLockedException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast('Couldn\'t save changes');
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
        else ...[
          if (_disbSuggestions.isEmpty)
            Text(
              'No matching outflow found near the loan date — pick one '
              'manually below.',
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
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _openLinkDisbursement,
              icon: const Icon(Icons.link, size: 16),
              label: const Text('Link a transaction',
                  style: TextStyle(fontSize: 12)),
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
            label: const Text('Record a payment',
                style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
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
    // Scheduled rows = GENERATED installments, as opposed to
    // manually-recorded MVP repayments (which carry NO scheduled split —
    // both scheduled_principal and scheduled_interest are 0). Keep any
    // row that has a principal OR interest split: interest-only loans
    // emit scheduled_principal = 0 for every period except the final
    // balloon, so filtering on principal>0 alone collapses a 6-month
    // interest-only plan to a single row. Compound / lump_sum schedules
    // are genuinely a single row and stay that way (their one row has
    // both splits > 0).
    final scheduled = _payments.where((p) {
      final m = p as Map;
      final sp = (m['scheduled_principal'] as num?)?.toDouble() ?? 0;
      final si = (m['scheduled_interest'] as num?)?.toDouble() ?? 0;
      return sp > 0 || si > 0;
    }).toList();
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
        // Correct a fat-fingered borrower / principal / rate / interest
        // type without delete-and-recreate.
        OutlinedButton.icon(
          onPressed: _openEditLoan,
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('Edit', style: TextStyle(fontSize: 12)),
        ),
        // Printable promissory-note / agreement (HTML → browser PDF).
        OutlinedButton.icon(
          onPressed: () => launchUrl(
              Uri.parse(widget.apiService.loanAgreementUrl(_loanId)),
              webOnlyWindowName: '_blank'),
          icon: const Icon(Icons.description_outlined, size: 16),
          label: const Text('Agreement', style: TextStyle(fontSize: 12)),
        ),
        // Early/full payoff: close the loan + void remaining installments.
        // Only meaningful while the loan is still active.
        if (status == 'active')
          OutlinedButton.icon(
            onPressed: _confirmPayoff,
            icon: Icon(Icons.task_alt, size: 16, color: context.positive),
            label: Text('Pay off in full',
                style: TextStyle(fontSize: 12, color: context.positive)),
          ),
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

  Future<void> _openEditLoan() async {
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
    _toast('Loan updated');
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

  Future<void> _confirmPayoff() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pay off in full?'),
        content: const Text(
            'Marks the loan as paid off and clears any remaining scheduled '
            'installments. This does not create a repayment — link the actual '
            'final transaction from the Repayments list so interest income '
            'stays accurate.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pay off'),
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
      _toast('Loan paid off');
    } catch (e) {
      // 409 if the loan isn't active anymore (e.g. raced with another tab).
      _toast(e.toString().contains('not active')
          ? 'Loan is no longer active'
          : 'Couldn\'t pay off loan');
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
      await widget.apiService.recordRepayment(_loanId,
          transactionId: s['transaction_id'].toString());
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
    _searchCtrl.dispose();
    _cashAmountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // A generous recent window; we filter client-side by sign + search.
      final txs = await widget.apiService.getTransactions(limit: 200);
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

  String _money(num v) {
    final fmt = NumberFormat.currency(
        symbol: widget.currency == 'MXN' ? r'MX$' : r'$', decimalDigits: 2);
    return fmt.format(v);
  }

  /// Candidate transactions: inflows (amount > 0) for a repayment,
  /// outflows (amount < 0) for a disbursement — matching the backend's
  /// sign convention — narrowed by the search box.
  List<Map<String, dynamic>> get _candidates {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _txs.whereType<Map<String, dynamic>>().where((t) {
      final amt = (t['amount'] as num?)?.toDouble() ?? 0;
      final signOk = _isRepayment ? amt > 0 : amt < 0;
      if (!signOk) return false;
      if (q.isEmpty) return true;
      final hay =
          '${t['description'] ?? ''} ${t['merchant'] ?? ''} ${t['category'] ?? ''}'
              .toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final title = _isRepayment ? 'Record a payment' : 'Link the disbursement';
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
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Bank transaction')),
                    ButtonSegment(value: 1, label: Text('Cash')),
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _candidates;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: _isRepayment
                  ? 'Search inflows (money received)'
                  : 'Search outflows (money sent)',
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        if (items.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _isRepayment
                      ? 'No incoming transactions found. Try the Cash tab '
                          'to record an off-bank repayment.'
                      : 'No outgoing transactions found.',
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
                    (t['description'] ?? t['merchant'] ?? 'Transaction')
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
          'Record a repayment that didn\'t come through a linked bank '
          'account (e.g. cash). It reduces the outstanding balance but '
          'isn\'t tied to a transaction.',
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _cashAmountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Amount received',
            prefixText: widget.currency == 'MXN' ? r'MX$ ' : r'$ ',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: _pickCashDate,
          borderRadius: BorderRadius.circular(10),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Received on',
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
              : const Text('Record cash payment'),
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
              ? 'That transaction is already linked'
              : 'Couldn\'t record that')));
    }
  }

  Future<void> _submitCash() async {
    final amount = double.tryParse(_cashAmountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid amount')));
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t record cash payment')));
    }
  }
}
