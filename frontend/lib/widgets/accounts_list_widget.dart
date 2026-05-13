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
      return Card(
        color: const Color(0xFF1A1A24),
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_balance_wallet_outlined,
                    size: 56, color: Colors.grey.shade700),
                const SizedBox(height: 14),
                const Text(
                  'No accounts yet',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Link a bank with Plaid, import a CSV, or add a manual\naccount from the Management tab to get started.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
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
              'ACCOUNTS',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white54,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
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
          ..._renderAccountsWithVaults(context, groupAccounts),
        ],
      ),
    );
  }

  /// Group accounts by (institution, account_type) within an already
  /// type-filtered group. When a cluster has multiple accounts (e.g. SoFi
  /// Savings + its vaults), pick the dominant one (largest balance) as the
  /// "primary" and render the rest indented below it as sub-accounts.
  /// This collapses SoFi vaults (Car, Cards, Emergency, Rent, Taxes, etc.)
  /// under SoFi Savings without losing them.
  List<Widget> _renderAccountsWithVaults(
      BuildContext context, List<dynamic> groupAccounts) {
    final clusters = <String, List<dynamic>>{};
    final order = <String>[];
    for (final acc in groupAccounts) {
      final inst = (acc['institution_name'] ?? '').toString();
      final type = (acc['account_type'] ?? '').toString().toLowerCase();
      final key = '$inst|$type';
      clusters.putIfAbsent(key, () {
        order.add(key);
        return <dynamic>[];
      }).add(acc);
    }

    final widgets = <Widget>[];
    for (final key in order) {
      final cluster = clusters[key]!;
      if (cluster.length == 1) {
        widgets.add(_buildAccountRow(context, cluster.first));
        continue;
      }
      // Pick the parent. The vaults (e.g. SoFi "Emergency", "Car", "Rent")
      // are nicknames the user attached to allocations inside their main
      // account — the main account itself is named after the bank product
      // ("SoFi Savings"). So we prefer:
      //   1. account whose name contains the account_type token
      //      (e.g. "Savings" in "SoFi Savings")
      //   2. otherwise an account whose name contains the institution name
      //   3. otherwise the largest-balance account
      cluster.sort((a, b) {
        final aName = (a['name'] ?? '').toString().toLowerCase();
        final bName = (b['name'] ?? '').toString().toLowerCase();
        final typeToken =
            (a['account_type'] ?? '').toString().toLowerCase();
        final instToken =
            (a['institution_name'] ?? '').toString().toLowerCase();

        int rank(String name) {
          if (typeToken.isNotEmpty && name.contains(typeToken)) return 0;
          if (instToken.isNotEmpty && name.contains(instToken)) return 1;
          return 2;
        }

        final ra = rank(aName);
        final rb = rank(bName);
        if (ra != rb) return ra.compareTo(rb);

        final ba = ((a['current_balance'] ?? 0.0) as num).toDouble().abs();
        final bb = ((b['current_balance'] ?? 0.0) as num).toDouble().abs();
        return bb.compareTo(ba);
      });
      final parent = cluster.first;
      final vaults = cluster.skip(1).toList();
      widgets.add(_buildAccountRow(context, parent));
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 12, 8),
          child: Column(
            children: vaults
                .map((v) => _buildVaultRow(context, v))
                .toList(),
          ),
        ),
      );
    }
    return widgets;
  }

  /// Compact sub-row for SoFi-style "vaults". Smaller type, no institution
  /// label (it's implied from the parent above), no chevron, indented.
  Widget _buildVaultRow(BuildContext context, dynamic acc) {
    final balance =
        ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    final sourceCurrency = (acc['currency'] ?? targetCurrency).toString();
    final name = (acc['name'] ?? 'Vault').toString();

    return InkWell(
      onTap: () {
        showAccountTransactionsPanel(
          context,
          account: acc,
          allAccounts: accounts,
          conversionFactor: conversionFactor,
          currencyFormat: currencyFormat,
          targetCurrency: targetCurrency,
          usdMxnRate: usdMxnRate,
          onBalanceUpdate: onBalanceUpdate,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 1,
              color: Colors.white12,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white70,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatCurrencyAmount(balance, sourceCurrency),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
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
    final name = (acc['name'] ?? 'Unknown Account').toString();
    final inst = (acc['institution_name'] ?? '').toString();
    final hasCrypto =
        acc['ticker_symbol'] != null && acc['crypto_amount'] != null;
    final needsConversion =
        usdMxnRate > 0 && sourceCurrency != targetCurrency;

    // Native value — this is the "real" amount the bank reported.
    final nativeText = formatCurrencyAmount(balance, sourceCurrency);
    // Converted amount only matters when there's an FX conversion to do.
    final convertedAmount = convertCurrency(
      balance,
      from: sourceCurrency,
      to: targetCurrency,
      usdMxnRate: usdMxnRate,
    );

    Widget primaryName = Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 600),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
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

    // Primary line is the NATIVE-currency value (what the bank actually
    // reports). The estimated conversion only appears when needed.
    Widget balanceText = Text(
      nativeText,
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
    } else if (needsConversion) {
      subBalance = Text(
        '≈ ${currencyFormat.format(convertedAmount)}',
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white38,
          fontStyle: FontStyle.italic,
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
          allAccounts: accounts,
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
