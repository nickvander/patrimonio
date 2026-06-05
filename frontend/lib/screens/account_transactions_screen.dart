import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../widgets/transactions_tab.dart';
import '../widgets/account_balance_chart.dart';
import '../services/preferences.dart';
import '../utils/account_category.dart';
import '../l10n/app_localizations.dart';

/// Per-account transaction history. Rendered as the body of a slide-from-
/// right side panel via [showAccountTransactionsPanel] — no Scaffold/AppBar
/// of its own. On narrow viewports the panel collapses to a bottom sheet.
class AccountTransactionsScreen extends StatefulWidget {
  final Map<String, dynamic> account;
  final List<dynamic> allAccounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String, double)? onBalanceUpdate;
  /// Optional inline rename action — when wired, the header surfaces a
  /// "Rename" entry in the overflow menu that lets the user set a
  /// nickname without leaving the panel.
  final Future<void> Function(String accountId, String nickname)?
      onRenameAccount;

  const AccountTransactionsScreen({
    super.key,
    required this.account,
    this.allAccounts = const [],
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onBalanceUpdate,
    this.onRenameAccount,
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
  List<dynamic> _balanceHistory = const [];
  // Low-balance alert thresholds (account id -> native-currency amount).
  Map<String, double> _accountAlerts = const {};

  /// Locally-tracked balance and nickname so this screen can reflect an edit
  /// immediately without writing back into the parent's shared map. The
  /// parent will pick up the real values on its next data refresh.
  late double _currentBalance;
  late String _nickname;

  @override
  void initState() {
    super.initState();
    _currentBalance =
        ((widget.account['current_balance'] as num?)?.toDouble()) ?? 0.0;
    _nickname = (widget.account['nickname'] ?? '').toString();
    _accountAlerts = Preferences.getAccountAlerts();
    _fetchTransactions();
    _fetchBalanceHistory();
    _hydrateAlerts();
  }

  Future<void> _hydrateAlerts() async {
    try {
      final raw = await _apiService.getSetting('account_balance_alerts');
      if (!mounted || raw is! Map) return;
      final next = <String, double>{};
      raw.forEach((k, v) {
        final d = v is num ? v.toDouble() : double.tryParse('$v');
        if (d != null && d > 0) next[k.toString()] = d;
      });
      setState(() => _accountAlerts = next);
      Preferences.setAccountAlerts(next);
    } catch (_) {
      // localStorage seed stands.
    }
  }

  bool get _alertEligible {
    final cat = categorizeAccount(widget.account['account_type']?.toString());
    return cat != AccountCategory.credit && cat != AccountCategory.loan;
  }

  String get _accountId => widget.account['id'].toString();

  void _showThresholdDialog() {
    final l = AppLocalizations.of(context);
    final currency =
        (widget.account['currency'] ?? 'USD').toString().toUpperCase();
    final existing = _accountAlerts[_accountId];
    final controller = TextEditingController(
      text: existing == null ? '' : existing.toStringAsFixed(0),
    );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctxLowBalanceAlertTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.acctxLowBalanceAlertBody,
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.acctxThresholdLabel,
                prefixText: r'$ ',
                suffixText: currency,
              ),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _saveThreshold(null);
              },
              child: Text(l.acctxRemoveAlert),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text);
              Navigator.pop(context);
              if (v != null && v > 0) _saveThreshold(v);
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    );
  }

  void _saveThreshold(double? value) {
    final next = Map<String, double>.from(_accountAlerts);
    final l = AppLocalizations.of(context);
    if (value == null) {
      next.remove(_accountId);
    } else {
      next[_accountId] = value;
    }
    setState(() => _accountAlerts = next);
    Preferences.setAccountAlerts(next);
    _apiService.putSetting('account_balance_alerts', next).catchError((_) {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            value == null ? l.acctxAlertRemoved : l.acctxAlertSaved),
      ),
    );
  }

  Future<void> _fetchBalanceHistory() async {
    final history =
        await _apiService.getAccountBalanceHistory(widget.account['id'].toString());
    if (mounted) setState(() => _balanceHistory = history);
  }

  @override
  void didUpdateWidget(covariant AccountTransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.account != oldWidget.account) {
      _currentBalance =
          ((widget.account['current_balance'] as num?)?.toDouble()) ?? 0.0;
      _nickname = (widget.account['nickname'] ?? '').toString();
      _fetchBalanceHistory();
    }
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

  void _showRenameDialog() {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: _nickname);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctxRenameAccount),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l.acctxNickname,
            hintText: widget.account['name']?.toString() ?? l.acctxAccountFallback,
          ),
          onSubmitted: (v) {
            Navigator.pop(context);
            final next = v.trim();
            setState(() => _nickname = next);
            widget.onRenameAccount
                ?.call(widget.account['id'].toString(), next);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.actionCancel)),
          FilledButton(
            onPressed: () async {
              final v = controller.text.trim();
              Navigator.pop(context);
              if (mounted) setState(() => _nickname = v);
              await widget.onRenameAccount
                  ?.call(widget.account['id'].toString(), v);
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    );
  }

  // Derive a small balance-history sparkline from the loaded transactions
  // by walking backward from the current balance. This avoids a new
  // backend endpoint and is "good enough" for the recent 30-day shape.
  Widget _buildBalanceSparkline() {
    final txs = _transactions ?? const [];
    final current = _currentBalance;

    // Walk transactions newest-first, treating amount > 0 as outflow:
    // balance(date - 1) = balance(date) + amount.
    final sorted = [...txs];
    sorted.sort((a, b) {
      final ad = DateTime.tryParse(a['date']?.toString() ?? '') ?? DateTime(2000);
      final bd = DateTime.tryParse(b['date']?.toString() ?? '') ?? DateTime(2000);
      return bd.compareTo(ad);
    });

    final today = DateTime.now();
    final cutoff = today.subtract(const Duration(days: 30));
    final dailyBalances = <DateTime, double>{today: current};
    var running = current;
    for (final tx in sorted) {
      final d = DateTime.tryParse(tx['date']?.toString() ?? '');
      if (d == null) continue;
      if (d.isBefore(cutoff)) break;
      final amt = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
      running += amt;
      dailyBalances[DateTime(d.year, d.month, d.day)] = running;
    }

    if (dailyBalances.length < 2) return const SizedBox.shrink();

    final orderedDays = dailyBalances.keys.toList()
      ..sort((a, b) => a.compareTo(b));
    final points = <FlSpot>[
      for (var i = 0; i < orderedDays.length; i++)
        FlSpot(i.toDouble(), dailyBalances[orderedDays[i]]!),
    ];

    final ys = points.map((p) => p.y).toList();
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() * 0.1 + 1;
    final isUp = points.last.y >= points.first.y;
    final color = isUp ? context.positive : context.pinkAccent;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 48,
        child: LineChart(
          LineChartData(
            minY: minY - pad,
            maxY: maxY + pad,
            gridData: const FlGridData(show: false),
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: points,
                isCurved: true,
                curveSmoothness: 0.25,
                color: color,
                barWidth: 2,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: color.withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditBalanceDialog() {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: _currentBalance.toString());
    final currency =
        (widget.account['currency'] ?? 'USD').toString().toUpperCase();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctxUpdateBalanceTitle(
            (widget.account['name'] ?? l.acctxAccountFallback).toString())),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          autofocus: true,
          onSubmitted: (_) {
            final newBalance = double.tryParse(controller.text);
            if (newBalance == null) return;
            Navigator.pop(context);
            setState(() => _currentBalance = newBalance);
            widget.onBalanceUpdate?.call(widget.account['id'], newBalance);
          },
          decoration: InputDecoration(
            labelText: l.acctxCurrentBalance,
            prefixText: r'$ ',
            suffixText: currency,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          ElevatedButton(
            onPressed: () {
              final newBalance = double.tryParse(controller.text);
              if (newBalance == null) return;
              Navigator.pop(context);
              setState(() => _currentBalance = newBalance);
              widget.onBalanceUpdate?.call(widget.account['id'], newBalance);
            },
            child: Text(l.actionSave),
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
        Divider(height: 1, color: context.hairline),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildHeader() {
    final l = AppLocalizations.of(context);
    final balance = _currentBalance.abs();
    final sourceCurrency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    final convertedBalance = convertCurrency(
      balance,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final needsConversion = widget.usdMxnRate > 0 &&
        sourceCurrency != widget.targetCurrency;
    final inst = (widget.account['institution_name'] ?? '').toString();
    final name = (widget.account['name'] ?? l.acctxAccountFallback).toString();

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
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: l.acctxAccountActions,
                onSelected: (v) {
                  switch (v) {
                    case 'balance':
                      _showEditBalanceDialog();
                    case 'rename':
                      _showRenameDialog();
                    case 'alert':
                      _showThresholdDialog();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'balance',
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(l.acctxUpdateBalance),
                    ),
                  ),
                  if (widget.onRenameAccount != null)
                    PopupMenuItem(
                      value: 'rename',
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.drive_file_rename_outline),
                        title: Text(l.acctxRenameAccount),
                      ),
                    ),
                  if (_alertEligible)
                    PopupMenuItem(
                      value: 'alert',
                      child: ListTile(
                        dense: true,
                        leading:
                            const Icon(Icons.notifications_active_outlined),
                        title: Text(_accountAlerts.containsKey(_accountId)
                            ? l.acctxEditLowBalanceAlert
                            : l.acctxSetLowBalanceAlert),
                      ),
                    ),
                ],
                icon: const Icon(Icons.more_vert, size: 20),
              ),
              IconButton(
                tooltip: l.actionClose,
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
                formatCurrencyAmount(balance, sourceCurrency),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: context.textPrimary,
                  fontFeatures: [const FontFeature.tabularFigures()],
                ),
              ),
              if (needsConversion) ...[
                const SizedBox(width: 8),
                Text(
                  '≈ ${widget.currencyFormat.format(convertedBalance)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.textFaint,
                    fontStyle: FontStyle.italic,
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
          _buildBalanceSparkline(),
          _buildLowBalanceBanner(),
        ],
      ),
    );
  }

  // Amber heads-up when the balance has fallen to/below the user's threshold.
  Widget _buildLowBalanceBanner() {
    final threshold = _accountAlerts[_accountId];
    if (threshold == null || _currentBalance > threshold) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final currency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    final color = context.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.acctxLowBalanceBanner(
                    formatCurrencyAmount(threshold, currency)),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context);
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
              l.acctxLoadError(_error!),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchTransactions,
              child: Text(l.acctxRetry),
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
            Text(
              l.acctxNoTransactionsTitle,
              style: TextStyle(fontSize: 16, color: context.textSubtle),
            ),
            const SizedBox(height: 8),
            Text(
              l.acctxNoTransactionsBody,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final sourceCurrency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          if (_balanceHistory.length >= 2) ...[
            AccountBalanceChart(
              points: _balanceHistory,
              currency: sourceCurrency,
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: TransactionsTab(
              transactions: _transactions!,
        accounts: widget.allAccounts,
        conversionFactor: widget.conversionFactor,
        currencyFormat: widget.currencyFormat,
        targetCurrency: widget.targetCurrency,
        usdMxnRate: widget.usdMxnRate,
        onUpdate: (id, {userCategory, userNotes, userDescription, accountId}) async {
          try {
            await _apiService.updateTransaction(
              id,
              userCategory: userCategory,
              userNotes: userNotes,
              userDescription: userDescription,
              accountId: accountId,
            );
            _fetchTransactions();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.acctxUpdateFailed(e.toString()))),
            );
          }
        },
        onDelete: (id) async {
          await _apiService.deleteTransaction(id);
          _fetchTransactions();
        },
            ),
          ),
        ],
      ),
    );
  }
}

/// Slide-from-right side panel that shows transactions for one account.
/// On narrow viewports this falls back to a bottom sheet.
Future<void> showAccountTransactionsPanel(
  BuildContext context, {
  required Map<String, dynamic> account,
  List<dynamic> allAccounts = const [],
  required double conversionFactor,
  required NumberFormat currencyFormat,
  required String targetCurrency,
  required double usdMxnRate,
  Function(String, double)? onBalanceUpdate,
  Future<void> Function(String, String)? onRenameAccount,
}) {
  final size = MediaQuery.sizeOf(context);
  final isNarrow = size.width < 700;

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context).acctxDismissBarrier,
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
              allAccounts: allAccounts,
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
              targetCurrency: targetCurrency,
              usdMxnRate: usdMxnRate,
              onBalanceUpdate: onBalanceUpdate,
              onRenameAccount: onRenameAccount,
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
