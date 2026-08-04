import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart' show moneyFieldPrefix, moneyFormat;
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

enum RecordMode { repayment, disbursement }

/// A bottom sheet to either designate an existing bank transaction
/// (repayment inflow / disbursement outflow) or — for repayments —
/// record a cash/off-bank payment by amount + date.
///
/// Pops `true` when something was recorded so the caller can refresh.
class RecordPaymentSheet extends StatefulWidget {
  final ApiService apiService;
  final String loanId;
  final String currency;
  final RecordMode mode;

  const RecordPaymentSheet({
    super.key,
    required this.apiService,
    required this.loanId,
    required this.currency,
    required this.mode,
  });

  @override
  State<RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends State<RecordPaymentSheet> {
  // Tab 0 = pick a bank transaction; tab 1 = cash (repayment only).
  int _tab = 0;
  List<dynamic> _txs = [];
  bool _loading = true;
  bool _submitting = false;
  Timer? _searchDebounce;
  final _searchCtrl = TextEditingController();
  final _cashAmountCtrl = TextEditingController();
  DateTime _cashDate = DateTime.now();

  bool get _isRepayment => widget.mode == RecordMode.repayment;

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
      // .rows: the picker only needs the candidate list, never the
      // X-Total-Count total that rides on the TxPage.
      final txs = (await widget.apiService.getTransactions(
        limit: 200,
        currency: widget.currency,
        sign: _isRepayment ? 'inflow' : 'outflow',
        query: _searchCtrl.text,
        // Don't offer a tx already reconciled to a loan — picking it would
        // only bounce with "already linked".
        excludeLinked: true,
      )).rows;
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

  /// Amount-field prefix for the loan's currency, from the house
  /// [moneyFieldPrefix] helper (`$ `, `MXN `) rather than hardcoded, so the
  /// field agrees with [_money] and every other money surface.
  String get _amountPrefix => moneyFieldPrefix(widget.currency);

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
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            // Mode switch (cash is repayment-only).
            if (_isRepayment)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                // House connected button group (shared single-select
                // control).
                child: ConnectedSegments<int>(
                  segments: [
                    ConnectedSegment(
                      value: 0,
                      label: AppLocalizations.of(
                        context,
                      ).lendSegBankTransaction,
                    ),
                    ConnectedSegment(
                      value: 1,
                      label: AppLocalizations.of(context).lendSegCash,
                    ),
                  ],
                  selected: _tab,
                  onSelected: (v) => setState(() => _tab = v),
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
            prefixText: _amountPrefix,
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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              DateFormat.yMMMd().format(_cashDate),
              style: TextStyle(color: context.textPrimary),
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _submitting ? null : _submitCash,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
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
        await widget.apiService.recordRepayment(
          widget.loanId,
          transactionId: txId,
        );
      } else {
        await widget.apiService.linkDisbursement(widget.loanId, txId);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('already')
                ? l10n.lendToastTxAlreadyLinked
                : l10n.lendToastCouldntRecordThat,
          ),
        ),
      );
    }
  }

  Future<void> _submitCash() async {
    final amount = double.tryParse(_cashAmountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).lendToastEnterValidAmount),
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final iso = DateFormat('yyyy-MM-dd').format(_cashDate);
      await widget.apiService.recordRepayment(
        widget.loanId,
        amount: amount,
        paidDate: iso,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).lendToastCouldntRecordCashPayment,
          ),
        ),
      );
    }
  }
}
