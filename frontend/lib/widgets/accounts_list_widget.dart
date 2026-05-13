import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../screens/account_transactions_screen.dart';
import '../utils/currency.dart';

class AccountsListWidget extends StatelessWidget {
  final List<dynamic> accounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String, double)? onBalanceUpdate;
  final Function(String)? onDeleteAccount;

  const AccountsListWidget({
    super.key,
    required this.accounts,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onBalanceUpdate,
    this.onDeleteAccount,
  });

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return const Card(
        color: Color(0xFF1A1A24),
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(
            child: Text(
              'No accounts linked yet. Use the Link button to add an institution.',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // Group accounts by main category
    final cashAccounts = <dynamic>[];
    final creditAccounts = <dynamic>[];
    final investmentAccounts = <dynamic>[];
    final cryptoAccounts = <dynamic>[];
    final loanAccounts = <dynamic>[];

    for (var acc in accounts) {
      final type = (acc['account_type'] ?? '').toString().toLowerCase();
      if ([
        'checking',
        'savings',
        'cd',
        'money market',
        'cash management',
      ].contains(type)) {
        cashAccounts.add(acc);
      } else if (['credit card', 'credit'].contains(type)) {
        creditAccounts.add(acc);
      } else if ([
        'ira',
        '401k',
        'hsa',
        'brokerage',
        'investment',
      ].contains(type)) {
        investmentAccounts.add(acc);
      } else if (['crypto'].contains(type)) {
        cryptoAccounts.add(acc);
      } else if (['student', 'mortgage', 'loan'].contains(type)) {
        loanAccounts.add(acc);
      } else {
        cashAccounts.add(acc); // fallback
      }
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Accounts',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                if (cashAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Cash',
                    cashAccounts,
                    Icons.wallet_rounded,
                    false,
                    const Color(0xFF00B0FF),
                  ),
                if (investmentAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Investments',
                    investmentAccounts,
                    Icons.show_chart_rounded,
                    false,
                    const Color(0xFF1DE9B6),
                  ),
                if (cryptoAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Crypto',
                    cryptoAccounts,
                    Icons.currency_bitcoin_rounded,
                    false,
                    const Color(0xFF651FFF),
                  ),
                if (creditAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Credit Cards',
                    creditAccounts,
                    Icons.credit_card_rounded,
                    true,
                    const Color(0xFFFF5252),
                  ),
                if (loanAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Loans & Mortgages',
                    loanAccounts,
                    Icons.home_rounded,
                    true,
                    const Color(0xFFFFD54F),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountGroup(
    BuildContext context,
    String title,
    List<dynamic> groupAccounts,
    IconData icon,
    bool isLiability,
    Color accentColor,
  ) {
    // Sort within group by balance descending
    groupAccounts.sort((a, b) {
      final balA = ((a['current_balance'] ?? 0.0) as num).toDouble().abs();
      final balB = ((b['current_balance'] ?? 0.0) as num).toDouble().abs();
      return balB.compareTo(balA);
    });

    final total = groupAccounts.fold<double>(0.0, (sum, acc) {
      final bal = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
      final sourceCurrency = (acc['currency'] ?? targetCurrency).toString();
      return sum +
          convertCurrency(
            bal,
            from: sourceCurrency,
            to: targetCurrency,
            usdMxnRate: usdMxnRate,
          );
    });

    return Container(
      margin: const EdgeInsets.only(bottom: 24.0),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 380;
              final headerIcon = Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: accentColor, size: 18),
              );
              final titleText = Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
              final totalText = Text(
                currencyFormat.format(total),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: accentColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              );

              if (isNarrow) {
                // Stack the total below the title so a long number can't
                // shove the title into ellipsis territory.
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          headerIcon,
                          const SizedBox(width: 12),
                          Expanded(child: titleText),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: totalText,
                      ),
                    ],
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    headerIcon,
                    const SizedBox(width: 12),
                    Expanded(child: titleText),
                    const SizedBox(width: 12),
                    totalText,
                  ],
                ),
              );
            },
          ),
          const Divider(color: Colors.white12, height: 1),
          ...groupAccounts.map((acc) => _buildAccountRow(context, acc)),
        ],
      ),
    );
  }

  /// One row inside an account group. Lays out two ways depending on the
  /// available width so the balance never overflows on narrow screens:
  ///   wide  : name+inst — — — — — — balance + companion + menu
  ///   narrow: name+inst stacked, balance below on its own line
  Widget _buildAccountRow(BuildContext context, dynamic acc) {
    final balance =
        ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    final sourceCurrency = (acc['currency'] ?? targetCurrency).toString();
    final reportedBalance = convertCurrency(
      balance,
      from: sourceCurrency,
      to: targetCurrency,
      usdMxnRate: usdMxnRate,
    );
    final name = (acc['name'] ?? 'Unknown Account').toString();
    final inst = (acc['institution_name'] ?? '').toString();
    final hasCrypto =
        acc['ticker_symbol'] != null && acc['crypto_amount'] != null;
    final isForeignCurrency =
        acc['currency'] != null && sourceCurrency != targetCurrency;

    // Pick a companion currency that's always different from the reporting
    // currency, so every row shows a second-currency reference value.
    final companionCurrency = isForeignCurrency
        ? sourceCurrency
        : (targetCurrency == 'USD' ? 'MXN' : 'USD');
    final companionAmount = convertCurrency(
      reportedBalance,
      from: targetCurrency,
      to: companionCurrency,
      usdMxnRate: usdMxnRate,
    );
    final showCompanion = usdMxnRate > 0 && !hasCrypto;

    Widget primaryName = Text(
      name,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    Widget secondaryMeta = inst.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              inst,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white54,
                letterSpacing: 0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );

    Widget balanceText = Text(
      currencyFormat.format(reportedBalance),
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    Widget? subBalance;
    if (hasCrypto) {
      subBalance = Text(
        '${acc['crypto_amount']} ${acc['ticker_symbol']}',
        style: const TextStyle(
          fontSize: 11,
          color: Color(0xFFAB8CFF),
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else if (showCompanion) {
      subBalance = Text(
        '≈ ${formatCurrencyAmount(companionAmount, companionCurrency)}',
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white38,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    Widget menuButton = PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18, color: Colors.white38),
      padding: EdgeInsets.zero,
      tooltip: 'Account actions',
      onSelected: (value) {
        if (value == 'delete') {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete account'),
              content: Text(
                  'Are you sure you want to delete "$name"? This will remove all its history.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    onDeleteAccount?.call(acc['id']);
                  },
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );

    return InkWell(
      onTap: () {
        showAccountTransactionsPanel(
          context,
          account: acc,
          conversionFactor: conversionFactor,
          currencyFormat: currencyFormat,
          targetCurrency: targetCurrency,
          usdMxnRate: usdMxnRate,
          onBalanceUpdate: onBalanceUpdate,
        );
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Anything below ~420px logical pixels collapses to a stacked
          // layout — the balance gets its own row underneath the name.
          final isNarrow = constraints.maxWidth < 420;
          if (isNarrow) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        primaryName,
                        secondaryMeta,
                        const SizedBox(height: 8),
                        balanceText,
                        if (subBalance != null) ...[
                          const SizedBox(height: 2),
                          subBalance,
                        ],
                      ],
                    ),
                  ),
                  menuButton,
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [primaryName, secondaryMeta],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    balanceText,
                    if (subBalance != null) ...[
                      const SizedBox(height: 2),
                      subBalance,
                    ],
                  ],
                ),
                menuButton,
              ],
            ),
          );
        },
      ),
    );
  }
}
