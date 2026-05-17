import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../screens/account_transactions_screen.dart';
import '../utils/account_category.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

class AccountsListWidget extends StatelessWidget {
  final List<dynamic> accounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String, double)? onBalanceUpdate;
  final Function(String)? onDeleteAccount;
  final Function(String accountId, String nickname)? onRenameAccount;
  /// Optional callback used by the empty state's "Add an account" button
  /// to jump to the Management tab.
  final VoidCallback? onGoToManagement;

  const AccountsListWidget({
    super.key,
    required this.accounts,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onBalanceUpdate,
    this.onDeleteAccount,
    this.onRenameAccount,
    this.onGoToManagement,
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
                Text(
                  'No accounts yet',
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Link a bank, import a CSV, or add a manual account to\nget started.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onGoToManagement,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: const Text('Add an account'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Group accounts by main category via the shared classifier so the
    // KPI strip and this widget stay in lockstep when new Plaid
    // subtypes appear (stock plan, roth, 403b, etc.).
    final cashAccounts = <dynamic>[];
    final creditAccounts = <dynamic>[];
    final investmentAccounts = <dynamic>[];
    final cryptoAccounts = <dynamic>[];
    final loanAccounts = <dynamic>[];
    final otherAccounts = <dynamic>[];

    // Track distinct unknown account_type tokens so we can both surface
    // them in the UI (the user sees what fell through and reports it)
    // and log them to the dev console (we catch them in telemetry).
    final unknownTypes = <String>{};

    for (var acc in accounts) {
      switch (categorizeAccount(acc['account_type']?.toString())) {
        case AccountCategory.cash:
          cashAccounts.add(acc);
        case AccountCategory.investment:
          investmentAccounts.add(acc);
        case AccountCategory.credit:
          creditAccounts.add(acc);
        case AccountCategory.crypto:
          cryptoAccounts.add(acc);
        case AccountCategory.loan:
          loanAccounts.add(acc);
        case AccountCategory.other:
          otherAccounts.add(acc);
          final raw = (acc['account_type'] ?? '').toString().trim();
          if (raw.isNotEmpty) unknownTypes.add(raw);
      }
    }

    // Telemetry: this fires once per build of the accounts list whenever
    // the classifier punts an account into Other. New Plaid subtypes
    // (like "stock plan" once was) show up here before users complain.
    if (unknownTypes.isNotEmpty) {
      debugPrint(
        'accounts_list_widget: ${unknownTypes.length} unknown '
        'account_type(s) landed in Other → ${unknownTypes.join(", ")}. '
        'Add to utils/account_category.dart if these belong elsewhere.',
      );
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ACCOUNTS',
              style: TextStyle(
                fontSize: 11,
                color: context.textSubtle,
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
                    'Credit cards',
                    creditAccounts,
                    Icons.credit_card_rounded,
                    true,
                    const Color(0xFFFF5252),
                  ),
                if (loanAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Loans & mortgages',
                    loanAccounts,
                    Icons.home_rounded,
                    true,
                    const Color(0xFFFFD54F),
                  ),
                if (otherAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    'Other',
                    otherAccounts,
                    Icons.category_outlined,
                    false,
                    const Color(0xFF90A4AE),
                    // Surface the raw subtypes that fell through so they
                    // can't sit hidden in Other indefinitely — the UI now
                    // self-reports its own classifier gaps.
                    subtitle: unknownTypes.isEmpty
                        ? null
                        : 'Unknown subtype${unknownTypes.length == 1 ? "" : "s"}: '
                            '${(unknownTypes.toList()..sort()).join(", ")}',
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
    Color accentColor, {
    /// Optional second line under the group title. Used by the Other
    /// group to surface the raw `account_type` tokens that fell
    /// through the classifier so the gap is visible at a glance.
    String? subtitle,
  }) {
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
        color: context.tint(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.tint(0.05)),
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
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
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

              final subtitleText = subtitle == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 4, left: 38),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
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
                      ?subtitleText,
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        headerIcon,
                        const SizedBox(width: 12),
                        Expanded(child: titleText),
                        const SizedBox(width: 12),
                        totalText,
                      ],
                    ),
                    ?subtitleText,
                  ],
                ),
              );
            },
          ),
          Divider(color: context.hairline, height: 1),
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
          onRenameAccount: onRenameAccount == null
              ? null
              : (id, nickname) async => onRenameAccount!(id, nickname),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 1,
              color: context.hairline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 13,
                  color: context.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatCurrencyAmount(balance, sourceCurrency),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.textMuted,
                fontFeatures: [const FontFeature.tabularFigures()],
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
    // Prefer the user's nickname over the bank-supplied name so a Plaid
    // default like "PLAID CHECKING 0001" can read as "Joint checking".
    final nickname = (acc['nickname'] ?? '').toString().trim();
    final rawName = (acc['name'] ?? 'Unknown account').toString();
    final name = nickname.isNotEmpty ? nickname : rawName;
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
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: context.textPrimary,
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
              style: TextStyle(
                fontSize: 12,
                color: context.textSubtle,
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
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: context.textPrimary,
        fontFeatures: [const FontFeature.tabularFigures()],
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
        style: TextStyle(
          fontSize: 11,
          color: context.textFaint,
          fontStyle: FontStyle.italic,
          fontFeatures: [const FontFeature.tabularFigures()],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    Widget menuButton = PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: context.textFaint),
      padding: EdgeInsets.zero,
      tooltip: 'Account actions',
      onSelected: (value) {
        if (value == 'rename') {
          _showRenameDialog(context, acc);
        } else if (value == 'delete') {
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
        if (onRenameAccount != null)
          PopupMenuItem(
            value: 'rename',
            child: Row(
              children: [
                Icon(Icons.drive_file_rename_outline,
                    size: 18, color: context.textMuted),
                const SizedBox(width: 8),
                const Text('Rename'),
              ],
            ),
          ),
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
          onRenameAccount: onRenameAccount == null
              ? null
              : (id, nickname) async => onRenameAccount!(id, nickname),
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

  /// Modal for setting a user-defined nickname on an account. Empty input
  /// clears the nickname (display falls back to the bank-supplied name).
  void _showRenameDialog(BuildContext context, dynamic acc) {
    final currentNickname = (acc['nickname'] ?? '').toString();
    final controller = TextEditingController(text: currentNickname);
    final rawName = (acc['name'] ?? '').toString();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Original: $rawName',
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                hintText: 'e.g. Joint checking',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 80,
              textInputAction: TextInputAction.done,
            ),
            Text(
              'Leave blank to clear and use the bank name.',
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              onRenameAccount?.call(
                acc['id'].toString(),
                controller.text.trim(),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
