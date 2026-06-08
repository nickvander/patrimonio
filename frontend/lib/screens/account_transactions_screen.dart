import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../widgets/transactions_tab.dart';
import '../widgets/account_balance_chart.dart';
import '../widgets/clabe_info.dart';
import '../widgets/add_holding_dialog.dart';
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
  /// Fired after a low-balance threshold is saved/removed so the opener
  /// (e.g. the dashboard) can refresh its notifications bell immediately.
  final VoidCallback? onAlertsChanged;

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
    this.onAlertsChanged,
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
  // Equity holdings (Plaid-synced or manually added by ticker + quantity).
  List<dynamic> _holdings = const [];
  bool _refreshingHoldings = false;
  // Dividend info keyed by symbol (annual rate, yield, est next ex-date, income).
  Map<String, dynamic> _dividends = const {};
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
    _fetchHoldings();
    _hydrateAlerts();
  }

  bool get _isInvestment =>
      categorizeAccount(widget.account['account_type']?.toString()) ==
      AccountCategory.investment;

  /// Holdings can only be hand-edited on a manual account — a Plaid-synced
  /// account's holdings are read-only (the institution owns them).
  bool get _isManualAccount =>
      (widget.account['integration_type'] ?? '').toString() == 'manual';

  Future<void> _fetchHoldings() async {
    if (!_isInvestment) return;
    try {
      final h = await _apiService.getAccountHoldings(_accountId);
      if (mounted) setState(() => _holdings = h);
      if (h.isNotEmpty) _fetchDividends();
    } catch (_) {/* best-effort */}
  }

  Future<void> _fetchDividends() async {
    try {
      final divs = await _apiService.getHoldingsDividends(_accountId);
      if (!mounted) return;
      setState(() => _dividends = {
            for (final d in divs)
              if (d is Map && d['symbol'] != null) d['symbol'].toString(): d,
          });
    } catch (_) {/* best-effort */}
  }

  Future<void> _addHolding() async {
    await showDialog<void>(
      context: context,
      builder: (_) => AddHoldingDialog(
        accountId: _accountId,
        onAdded: () {
          _fetchHoldings();
          _fetchBalanceHistory();
        },
      ),
    );
  }

  Future<void> _refreshHoldings() async {
    setState(() => _refreshingHoldings = true);
    try {
      final h = await _apiService.refreshHoldings(_accountId);
      if (mounted) setState(() => _holdings = h);
      _fetchDividends();
      _fetchBalanceHistory();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _refreshingHoldings = false);
    }
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
    widget.onAlertsChanged?.call();
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

  Widget _buildHoldings(String currency) {
    final es = Localizations.localeOf(context).languageCode == 'es';
    final fmt = moneyFormat(currency);
    double total = 0;
    for (final h in _holdings) {
      total += (h['value'] is num)
          ? (h['value'] as num).toDouble()
          : double.tryParse('${h['value']}') ?? 0;
    }
    return Container(
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                es ? 'POSICIONES' : 'HOLDINGS',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: context.textSubtle),
              ),
              const Spacer(),
              if (_holdings.isNotEmpty && _isManualAccount)
                IconButton(
                  tooltip: es ? 'Actualizar precios' : 'Refresh prices',
                  visualDensity: VisualDensity.compact,
                  icon: _refreshingHoldings
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.refresh, size: 18, color: context.tealAccent),
                  onPressed: _refreshingHoldings ? null : _refreshHoldings,
                ),
              if (_isManualAccount)
                TextButton.icon(
                  onPressed: _addHolding,
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(es ? 'Agregar' : 'Add'),
                ),
            ],
          ),
          if (_holdings.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
              child: Text(
                _isManualAccount
                    ? (es
                        ? 'Sin posiciones todavía. Agrega acciones por símbolo (ticker).'
                        : 'No holdings yet. Add shares by ticker.')
                    : (es ? 'Sin posiciones.' : 'No holdings.'),
                style: TextStyle(fontSize: 12.5, color: context.textFaint),
              ),
            )
          else ...[
            for (final h in _holdings) _holdingRow(h, fmt, es),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(children: [
                const Divider(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(es ? 'Total' : 'Total',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: context.textSubtle)),
                    Text(fmt.format(total),
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ],
                ),
                if (_totalDividendIncome() > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                            es
                                ? 'Ingreso anual estimado (dividendos)'
                                : 'Est. annual income (dividends)',
                            style: TextStyle(
                                fontSize: 11.5, color: context.tealAccent)),
                        Text(fmt.format(_totalDividendIncome()),
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: context.tealAccent,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                      ],
                    ),
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  double _totalDividendIncome() {
    double t = 0;
    for (final d in _dividends.values) {
      t += (d is Map ? (d['annual_income'] as num?)?.toDouble() : null) ?? 0;
    }
    return t;
  }

  Widget _dividendLine(String symbol, NumberFormat fmt, bool es) {
    final d = _dividends[symbol];
    final income =
        d == null ? 0.0 : ((d['annual_income'] as num?)?.toDouble() ?? 0.0);
    if (d == null || income <= 0) return const SizedBox.shrink();
    final yieldPct = (d['yield_pct'] as num?)?.toDouble();
    final next = d['est_next_ex_date']?.toString();
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        [
          'Div: ${fmt.format(income)}${es ? '/año' : '/yr'}',
          if (yieldPct != null) '${yieldPct.toStringAsFixed(2)}%',
          if (next != null && next.isNotEmpty) '${es ? 'próx.' : 'next'} ~$next',
        ].join('  ·  '),
        style: TextStyle(
            fontSize: 11,
            color: context.tealAccent,
            fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }

  Widget _holdingRow(dynamic h, NumberFormat fmt, bool es) {
    final symbol = (h['symbol'] ?? '').toString();
    final qty = (h['quantity'] is num)
        ? (h['quantity'] as num).toDouble()
        : double.tryParse('${h['quantity']}') ?? 0;
    final price = (h['price'] is num)
        ? (h['price'] as num).toDouble()
        : double.tryParse('${h['price'] ?? ''}');
    final value = (h['value'] is num)
        ? (h['value'] as num).toDouble()
        : double.tryParse('${h['value'] ?? ''}');
    final qtyStr =
        qty == qty.roundToDouble() ? qty.toStringAsFixed(0) : qty.toStringAsFixed(2);
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(symbol,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: context.textPrimary)),
                Text(
                  '$qtyStr ${es ? 'acciones' : 'shares'}'
                  '${price != null ? ' · ${fmt.format(price)}' : ''}',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: context.textSubtle,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                _dividendLine(symbol, fmt, es),
              ],
            ),
          ),
          Text(
            value != null ? fmt.format(value) : (es ? 'sin precio' : 'no price'),
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: value != null ? context.textPrimary : context.warning,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          if (_isManualAccount)
            IconButton(
              icon: Icon(Icons.close, size: 15, color: context.textFaint),
              visualDensity: VisualDensity.compact,
              tooltip: es ? 'Eliminar' : 'Remove',
              onPressed: () => _deleteHolding(h),
            ),
        ],
      ),
    );
  }

  Future<void> _deleteHolding(dynamic h) async {
    try {
      await _apiService.deleteHolding(_accountId, (h['id'] ?? '').toString());
      _fetchHoldings();
      _fetchBalanceHistory();
    } catch (_) {/* best-effort */}
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
      // An investment account (e.g. a manual stock-plan / NetBenefits position)
      // may hold shares but have no cash transactions — show the holdings view
      // instead of a bare "no transactions" message.
      if (_isInvestment) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_buildHoldings('USD')],
          ),
        );
      }
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
      // Left inset matches the header's 24px so the CLABE card + transaction
      // list line up with the account name/balance above (was 16 → an 8px
      // step-in that read as misaligned).
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
      child: Column(
        children: [
          if ((widget.account['clabe'] ?? '').toString().isNotEmpty) ...[
            ClabeInfoCard(
              clabe: widget.account['clabe'].toString(),
              holder: widget.account['holder_name']?.toString(),
            ),
            const SizedBox(height: 12),
          ],
          if (_balanceHistory.length >= 2) ...[
            AccountBalanceChart(
              points: _balanceHistory,
              currency: sourceCurrency,
            ),
            const SizedBox(height: 12),
          ],
          if (_isInvestment && _holdings.isNotEmpty) ...[
            _buildHoldings('USD'),
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
  VoidCallback? onAlertsChanged,
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
              onAlertsChanged: onAlertsChanged,
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
