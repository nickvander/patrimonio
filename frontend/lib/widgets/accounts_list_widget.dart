import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
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
  /// Optional callback for the "Revalue" affordance on manual-asset rows
  /// (real estate / private equity / vehicles / etc). Receives the
  /// account id, the new balance, and an optional note about why the
  /// value moved. When null the popup menu entry is hidden.
  final Function(String accountId, double balance, String? notes)?
      onRevalueAccount;
  /// Opens the Add-account dialog directly from the empty state's
  /// "Add an account" button (instead of bouncing to Settings).
  final VoidCallback? onAddAccount;
  /// Forwarded to the account panel so a low-balance threshold change
  /// refreshes the dashboard's notifications bell immediately.
  final VoidCallback? onAlertsChanged;

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
    this.onRevalueAccount,
    this.onAddAccount,
    this.onAlertsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (accounts.isEmpty) {
      return Card(
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
                  l.pfNoAccountsYet,
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.pfNoAccountsBody,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onAddAccount,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: Text(l.pfAddAnAccount),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.positive,
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
    final realAssetAccounts = <dynamic>[];
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
        case AccountCategory.realAsset:
          realAssetAccounts.add(acc);
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
              l.pfAccountsHeader,
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
                    l.pfGroupCash,
                    cashAccounts,
                    Icons.wallet_rounded,
                    false,
                    context.info,
                  ),
                if (investmentAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    l.pfGroupInvestments,
                    investmentAccounts,
                    Icons.show_chart_rounded,
                    false,
                    context.tealAccent,
                  ),
                if (cryptoAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    l.pfGroupCrypto,
                    cryptoAccounts,
                    Icons.currency_bitcoin_rounded,
                    false,
                    context.purpleAccent,
                  ),
                if (creditAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    l.pfGroupCreditCards,
                    creditAccounts,
                    Icons.credit_card_rounded,
                    true,
                    context.negative,
                  ),
                if (loanAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    l.pfGroupLoans,
                    loanAccounts,
                    Icons.home_rounded,
                    true,
                    context.yellowAccent,
                  ),
                if (realAssetAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    l.pfGroupRealAssets,
                    realAssetAccounts,
                    Icons.maps_home_work_rounded,
                    false,
                    context.yellowAccent,
                  ),
                if (otherAccounts.isNotEmpty)
                  _buildAccountGroup(
                    context,
                    l.pfGroupOther,
                    otherAccounts,
                    Icons.category_outlined,
                    false,
                    context.neutralAccent,
                    // Surface the raw subtypes that fell through so they
                    // can't sit hidden in Other indefinitely — the UI now
                    // self-reports its own classifier gaps.
                    subtitle: unknownTypes.isEmpty
                        ? null
                        : l.pfUnknownSubtypes(
                            unknownTypes.length,
                            (unknownTypes.toList()..sort()).join(", "),
                          ),
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
    // Cluster by INSTITUTION (within the already type-filtered category) so all
    // of a bank's accounts stay together — e.g. SoFi Checking + Savings + its
    // vaults cluster as one "SoFi" block rather than scattering by balance and
    // leaving the vaults stranded next to an unrelated bank (Nu).
    final clusters = <String, List<dynamic>>{};
    final order = <String>[];
    for (final acc in groupAccounts) {
      final inst = (acc['institution_name'] ?? '').toString();
      clusters.putIfAbsent(inst, () {
        order.add(inst);
        return <dynamic>[];
      }).add(acc);
    }

    final l = AppLocalizations.of(context);
    double bal(dynamic a) =>
        ((a['current_balance'] ?? 0.0) as num).toDouble().abs();
    // Converted-to-target total of a vault list, for the collapsed summary.
    double vaultTotal(List<dynamic> vs) => vs.fold<double>(
          0.0,
          (s, v) =>
              s +
              convertCurrency(
                ((v['current_balance'] ?? 0.0) as num).toDouble(),
                from: (v['currency'] ?? targetCurrency).toString(),
                to: targetCurrency,
                usdMxnRate: usdMxnRate,
              ),
        );

    final widgets = <Widget>[];
    for (final inst in order) {
      final cluster = clusters[inst]!;
      if (cluster.length == 1) {
        widgets.add(_buildAccountRow(context, cluster.first));
        continue;
      }
      final instToken = inst.toLowerCase();
      // A "vault" is a user-nicknamed sub-account (SoFi "Car", "Rent", …) whose
      // name matches neither its account-type token nor the bank name. A real
      // product (Checking, Savings, a 401k) does.
      bool isVault(dynamic acc) {
        final name = (acc['name'] ?? '').toString().toLowerCase();
        final typeTok =
            (acc['account_type'] ?? '').toString().toLowerCase().split(' ').first;
        if (typeTok.isNotEmpty && name.contains(typeTok)) return false;
        if (instToken.isNotEmpty && name.contains(instToken)) return false;
        return true;
      }

      final products = cluster.where((a) => !isVault(a)).toList()
        ..sort((a, b) => bal(b).compareTo(bal(a)));
      final vaults = cluster.where(isVault).toList()
        ..sort((a, b) => bal(b).compareTo(bal(a)));

      if (products.isEmpty) {
        // All siblings (no real product) — institution-scoped header + the
        // vaults collapsed beneath it (tap to expand).
        widgets.add(_buildVaultClusterHeader(context, cluster));
        widgets.add(_CollapsibleVaults(
          label: l.pfVaults,
          count: cluster.length,
          totalLabel: currencyFormat.format(vaultTotal(cluster)),
          rows: cluster.map((v) => _buildVaultRow(context, v)).toList(),
        ));
        continue;
      }

      // Nest the vaults under the SAVINGS product if there is one (vaults are
      // savings buckets); otherwise under the last/smallest product. Collapsed
      // by default — one "Vaults · N · $total" line that expands on tap —
      // so a bank with six buckets doesn't eat six rows.
      final savingsIdx = products.indexWhere((a) =>
          (a['account_type'] ?? '').toString().toLowerCase().contains('savings'));
      final attachIdx = savingsIdx >= 0 ? savingsIdx : products.length - 1;
      for (var i = 0; i < products.length; i++) {
        widgets.add(_buildAccountRow(context, products[i]));
        if (i == attachIdx && vaults.isNotEmpty) {
          widgets.add(_CollapsibleVaults(
            label: l.pfVaults,
            count: vaults.length,
            totalLabel: currencyFormat.format(vaultTotal(vaults)),
            rows: vaults.map((v) => _buildVaultRow(context, v)).toList(),
          ));
        }
      }
    }
    return widgets;
  }

  /// Header for a cluster of sibling vaults that has no real parent account.
  /// Labels the group by institution + a generic "Vaults" descriptor (SoFi /
  /// Ally-style sub-accounts) with the combined total — instead of borrowing
  /// one vault's name (which read as a credit-card account).
  Widget _buildVaultClusterHeader(BuildContext context, List<dynamic> cluster) {
    final inst = (cluster.first['institution_name'] ?? '').toString();
    final type = (cluster.first['account_type'] ?? '').toString().toLowerCase();
    final l = AppLocalizations.of(context);
    final descriptor = type.contains('cash management')
        ? l.pfVaults
        : l.pfAccountsDescriptor;
    final total = cluster.fold<double>(0.0, (sum, acc) {
      final bal = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
      final cur = (acc['currency'] ?? targetCurrency).toString();
      return sum +
          convertCurrency(bal,
              from: cur, to: targetCurrency, usdMxnRate: usdMxnRate);
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              inst.isEmpty ? descriptor : l.pfInstDescriptor(inst, descriptor),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            currencyFormat.format(total),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Compact sub-row for SoFi-style "vaults". Smaller type, no institution
  /// label (it's implied from the parent above), no chevron, indented.
  Widget _buildVaultRow(BuildContext context, dynamic acc) {
    final balance =
        ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    final sourceCurrency = (acc['currency'] ?? targetCurrency).toString();
    final name =
        (acc['name'] ?? AppLocalizations.of(context).pfVault).toString();

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
          onAlertsChanged: onAlertsChanged,
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
    final l = AppLocalizations.of(context);
    final balance =
        ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    final sourceCurrency = (acc['currency'] ?? targetCurrency).toString();
    // Prefer the user's nickname over the bank-supplied name so a Plaid
    // default like "PLAID CHECKING 0001" can read as "Joint checking".
    final nickname = (acc['nickname'] ?? '').toString().trim();
    final rawNameValue = (acc['name'] ?? '').toString();
    final rawName =
        rawNameValue.isEmpty ? l.pfUnknownAccount : rawNameValue;
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
          fontSize: 14,
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
        fontSize: 15,
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
        style: TextStyle(
          fontSize: 11,
          color: context.purpleAccent,
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

    // Manual assets (real estate, private equity, vehicles, etc.) don't
    // auto-sync — they need a periodic "Revalue" affordance so the user
    // can mark the asset to the current market. The set must match the
    // "Real assets" group in add_account_dialog.dart's _typeGroups.
    final accountTypeRaw = (acc['account_type'] ?? '').toString().toLowerCase();
    final isManualAsset = const {
      'real estate',
      'real_estate',
      'vehicle',
      'private equity',
      'private_equity',
      'collectibles',
      'other asset',
      'other_asset',
    }.contains(accountTypeRaw);

    Widget menuButton = PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: context.textFaint),
      padding: EdgeInsets.zero,
      tooltip: l.pfAccountActions,
      onSelected: (value) {
        if (value == 'rename') {
          _showRenameDialog(context, acc);
        } else if (value == 'revalue') {
          _showRevalueDialog(context, acc);
        } else if (value == 'delete') {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l.pfDeleteAccountTitle),
              content: Text(l.pfDeleteAccountConfirm(name)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.actionCancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    onDeleteAccount?.call(acc['id']);
                  },
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent),
                  child: Text(l.pfDelete),
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
                Text(l.pfRename),
              ],
            ),
          ),
        if (isManualAsset && onRevalueAccount != null)
          PopupMenuItem(
            value: 'revalue',
            child: Row(
              children: [
                Icon(Icons.price_change_outlined,
                    size: 18, color: context.textMuted),
                const SizedBox(width: 8),
                Text(l.pfRevalue),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              const Icon(Icons.delete_outline,
                  size: 18, color: Colors.redAccent),
              const SizedBox(width: 8),
              Text(l.pfDelete,
                  style: const TextStyle(color: Colors.redAccent)),
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
          onAlertsChanged: onAlertsChanged,
        );
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Anything below ~420px logical pixels collapses to a stacked
          // layout — the balance gets its own row underneath the name.
          final isNarrow = constraints.maxWidth < 420;
          if (isNarrow) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
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
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
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

  /// Modal for the "Revalue" affordance on a manual-asset row. Pre-fills
  /// the current balance, takes a new balance + optional note about
  /// what changed (a Zillow comp, a new appraisal, an unrealized
  /// share-class round, etc.). On Save the parent widget owns the API
  /// call + list refresh via [onRevalueAccount].
  void _showRevalueDialog(BuildContext context, dynamic acc) {
    final l = AppLocalizations.of(context);
    final currentBalance =
        ((acc['current_balance'] ?? 0.0) as num).toDouble();
    final balanceCtrl =
        TextEditingController(text: currentBalance.toStringAsFixed(2));
    final notesCtrl = TextEditingController();
    final currency =
        (acc['currency'] ?? 'USD').toString().toUpperCase();
    final name = (acc['nickname']?.toString().trim().isNotEmpty == true
        ? acc['nickname']
        : acc['name']) ?? l.pfAssetFallback;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: Text(l.pfRevalueTitle(name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.pfRevalueCurrent(
                  currentBalance.toStringAsFixed(2), currency),
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: balanceCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              decoration: InputDecoration(
                labelText: l.pfNewBalance,
                prefixText: r'$ ',
                suffixText: currency,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l.pfNotesOptional,
                hintText: l.pfNotesHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l.pfHistoryPointNote,
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(balanceCtrl.text.trim());
              if (parsed == null) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                      content: Text(l.pfEnterNumericBalance)),
                );
                return;
              }
              final note = notesCtrl.text.trim();
              Navigator.pop(ctx);
              onRevalueAccount?.call(
                acc['id'].toString(),
                parsed,
                note.isEmpty ? null : note,
              );
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    );
  }

  /// Modal for setting a user-defined nickname on an account. Empty input
  /// clears the nickname (display falls back to the bank-supplied name).
  void _showRenameDialog(BuildContext context, dynamic acc) {
    final l = AppLocalizations.of(context);
    final currentNickname = (acc['nickname'] ?? '').toString();
    final controller = TextEditingController(text: currentNickname);
    final rawName = (acc['name'] ?? '').toString();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.pfRenameAccountTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.pfRenameOriginal(rawName),
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.pfNickname,
                hintText: l.pfNicknameHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 80,
              textInputAction: TextInputAction.done,
            ),
            Text(
              l.pfRenameBlankHint,
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              onRenameAccount?.call(
                acc['id'].toString(),
                controller.text.trim(),
              );
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    );
  }
}

/// Collapsible group of "vault" sub-accounts (SoFi buckets, Nu cajitas). Shows
/// one summary line — "Vaults · N · $total" — that expands to the individual
/// rows on tap, so a bank with several buckets doesn't consume several rows.
class _CollapsibleVaults extends StatefulWidget {
  final String label;
  final int count;
  final String totalLabel;
  final List<Widget> rows;

  const _CollapsibleVaults({
    required this.label,
    required this.count,
    required this.totalLabel,
    required this.rows,
  });

  @override
  State<_CollapsibleVaults> createState() => _CollapsibleVaultsState();
}

class _CollapsibleVaultsState extends State<_CollapsibleVaults> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 40, right: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(_open ? Icons.expand_more : Icons.chevron_right,
                      size: 18, color: context.textSubtle),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.label} · ${widget.count}',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: context.textSubtle),
                  ),
                  const Spacer(),
                  Text(
                    widget.totalLabel,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: context.textSubtle,
                        fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 160),
            sizeCurve: Curves.easeOut,
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.rows,
            ),
          ),
        ],
      ),
    );
  }
}
