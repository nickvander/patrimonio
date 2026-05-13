import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../widgets/transactions_tab.dart';

/// Per-account transaction history. Rendered as the body of a slide-from-
/// right side panel via [showAccountTransactionsPanel] — no Scaffold/AppBar
/// of its own. On narrow viewports the panel collapses to a bottom sheet.
class AccountTransactionsScreen extends StatefulWidget {
  final Map<String, dynamic> account;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String, double)? onBalanceUpdate;

  const AccountTransactionsScreen({
    super.key,
    required this.account,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onBalanceUpdate,
  });

  @override
  State<AccountTransactionsScreen> createState() =>
      _AccountTransactionsScreenState();
}

class _AccountTransactionsScreenState extends State<AccountTransactionsScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;
  List<dynamic>? _transactions;

  @override
  void initState() {
    super.initState();
    _fetchTransactions();
  }

  Future<void> _fetchTransactions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final txs = await _apiService.getAccountTransactions(
        widget.account['id'],
      );
      setState(() {
        _transactions = txs;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _showEditBalanceDialog() {
    final controller = TextEditingController(
      text: widget.account['current_balance'].toString(),
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        title: Text('Update ${widget.account['name']} balance'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Current balance (${widget.account['currency']})',
            prefixText: '\$ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newBalance = double.tryParse(controller.text);
              if (newBalance != null) {
                Navigator.pop(context);
                widget.onBalanceUpdate
                    ?.call(widget.account['id'], newBalance);
                setState(() {
                  widget.account['current_balance'] = newBalance;
                });
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        const Divider(height: 1, color: Colors.white12),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildHeader() {
    final balance =
        ((widget.account['current_balance'] ?? 0.0) as num).toDouble().abs();
    final sourceCurrency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    final reportedBalance = convertCurrency(
      balance,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final inst = (widget.account['institution_name'] ?? '').toString();
    final name = (widget.account['name'] ?? 'Account').toString();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (inst.isNotEmpty)
                      Text(
                        inst.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Update balance',
                icon: const Icon(Icons.edit_outlined,
                    size: 18, color: Color(0xFF00E676)),
                onPressed: _showEditBalanceDialog,
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                widget.currencyFormat.format(reportedBalance),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (sourceCurrency != widget.targetCurrency) ...[
                const SizedBox(width: 8),
                Text(
                  '≈ ${formatCurrencyAmount(balance, sourceCurrency)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white38,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Error loading transactions: $_error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchTransactions,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_transactions == null || _transactions!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 64, color: Colors.grey[800]),
            const SizedBox(height: 16),
            const Text(
              'No transactions yet',
              style: TextStyle(fontSize: 16, color: Colors.white54),
            ),
            const SizedBox(height: 8),
            Text(
              'Records might just be starting, or offline accounts have no history.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: TransactionsTab(
        transactions: _transactions!,
        conversionFactor: widget.conversionFactor,
        currencyFormat: widget.currencyFormat,
        targetCurrency: widget.targetCurrency,
        usdMxnRate: widget.usdMxnRate,
        onUpdate: (id, {userCategory, userNotes, accountId}) async {
          try {
            await _apiService.updateTransaction(
              id,
              userCategory: userCategory,
              userNotes: userNotes,
              accountId: accountId,
            );
            _fetchTransactions();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to update transaction: $e')),
            );
          }
        },
      ),
    );
  }
}

/// Slide-from-right side panel that shows transactions for one account.
/// On narrow viewports this falls back to a bottom sheet.
Future<void> showAccountTransactionsPanel(
  BuildContext context, {
  required Map<String, dynamic> account,
  required double conversionFactor,
  required NumberFormat currencyFormat,
  required String targetCurrency,
  required double usdMxnRate,
  Function(String, double)? onBalanceUpdate,
}) {
  final size = MediaQuery.sizeOf(context);
  final isNarrow = size.width < 700;

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, secAnim) {
      return Align(
        alignment:
            isNarrow ? Alignment.bottomCenter : Alignment.centerRight,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: isNarrow ? size.width : 560,
            height: isNarrow ? size.height * 0.92 : size.height,
            decoration: BoxDecoration(
              color: const Color(0xFF15151E),
              borderRadius: isNarrow
                  ? const BorderRadius.vertical(top: Radius.circular(20))
                  : const BorderRadius.horizontal(left: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(-4, 0),
                ),
              ],
            ),
            child: AccountTransactionsScreen(
              account: account,
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
              targetCurrency: targetCurrency,
              usdMxnRate: usdMxnRate,
              onBalanceUpdate: onBalanceUpdate,
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, secAnim, child) {
      final tween = Tween<Offset>(
        begin: isNarrow ? const Offset(0, 1) : const Offset(1, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic));
      return SlideTransition(position: anim.drive(tween), child: child);
    },
  );
}
