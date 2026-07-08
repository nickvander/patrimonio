import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../screens/account_transactions_screen.dart';
import '../utils/account_category.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/theme_colors.dart';

/// Width of the trailing slot at the right edge of every account-style row:
/// the account rows' more_vert menu button, the collapsible headers'
/// chevrons, and the header/vault-row spacers all occupy exactly this width,
/// so balances and totals share one right edge (8px row padding + this slot).
/// Kept as an explicit shared constant because IconButton-style widgets
/// shrink to ~32px on desktop/web (shrinkWrap tap targets + compact visual
/// density), which would otherwise misalign the balance column per platform.
const double _kTrailingSlotWidth = 48;

/// Screen-reader label for an account-style row, built from the same values
/// the row renders: display name (with a trailing "••1234" mask spoken as
/// "ending in 1234" instead of bullet glyphs) followed by the row's
/// native-currency balance. Mask regex mirrors [maskAwareNameText].
String _accountRowSemanticsLabel(
    AppLocalizations l, String name, String balanceText) {
  final m = RegExp(r'^(.*\S)\s+••(\S{1,6})$').firstMatch(name);
  if (m == null) return '$name, $balanceText';
  return '${m.group(1)}, ${l.ovwEndingIn(m.group(2)!)}, $balanceText';
}

class AccountsListWidget extends StatefulWidget {
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
  State<AccountsListWidget> createState() => _AccountsListWidgetState();
}

class _AccountsListWidgetState extends State<AccountsListWidget> {
  // Proxy getters: the render helpers below were written against bare field
  // names while this was a StatelessWidget. Exposing them as getters keeps
  // those method bodies unchanged after the StatefulWidget split.
  List<dynamic> get accounts => widget.accounts;
  double get conversionFactor => widget.conversionFactor;
  NumberFormat get currencyFormat => widget.currencyFormat;
  String get targetCurrency => widget.targetCurrency;
  double get usdMxnRate => widget.usdMxnRate;
  Function(String, double)? get onBalanceUpdate => widget.onBalanceUpdate;
  Function(String)? get onDeleteAccount => widget.onDeleteAccount;
  Function(String, String)? get onRenameAccount => widget.onRenameAccount;
  Function(String, double, String?)? get onRevalueAccount =>
      widget.onRevalueAccount;
  VoidCallback? get onAddAccount => widget.onAddAccount;
  VoidCallback? get onAlertsChanged => widget.onAlertsChanged;

  // Local UI state (collapse / filter), kept on the State so a silent data
  // refresh doesn't reset which groups are open or what's typed in search.
  final Set<String> _collapsed = {};
  bool _collapseInitialized = false;
  bool _hideZero = false;
  final TextEditingController _searchCtl = TextEditingController();
  String _search = '';

  // Past this many accounts we (a) show the search box and (b) start every
  // group collapsed, so a long list opens as a scannable set of subtotal
  // headers instead of a wall of rows.
  static const int _longListThreshold = 8;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  bool _matchesSearch(dynamic acc) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay = [
      acc['nickname'],
      acc['name'],
      acc['official_name'],
      acc['institution_name'],
      acc['account_type'],
    ].where((e) => e != null).map((e) => e.toString().toLowerCase()).join(' ');
    return hay.contains(q);
  }

  bool _isZeroBalance(dynamic acc) =>
      ((acc['current_balance'] ?? 0.0) as num).toDouble().abs() < 0.005;

  bool _passesFilters(dynamic acc) =>
      _matchesSearch(acc) && (!_hideZero || !_isZeroBalance(acc));

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

    // Apply search + hide-zero before grouping so headers, subtotals and
    // counts all reflect exactly what's shown.
    final visibleAccounts = accounts.where(_passesFilters).toList();

    for (var acc in visibleAccounts) {
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
          // 'other' is an explicitly supported subtype, not a classifier
          // gap — only genuinely unrecognized tokens get surfaced.
          if (raw.isNotEmpty && raw.toLowerCase() != 'other') {
            unknownTypes.add(raw);
          }
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

    // Titles of the groups that will render, in display order. Seeds the
    // default-collapsed set; _buildAccountGroup keys its collapse state on
    // the same title.
    final groupTitles = <String>[
      if (cashAccounts.isNotEmpty) l.pfGroupCash,
      if (investmentAccounts.isNotEmpty) l.pfGroupInvestments,
      if (cryptoAccounts.isNotEmpty) l.pfGroupCrypto,
      if (creditAccounts.isNotEmpty) l.pfGroupCreditCards,
      if (loanAccounts.isNotEmpty) l.pfGroupLoans,
      if (realAssetAccounts.isNotEmpty) l.pfGroupRealAssets,
      if (otherAccounts.isNotEmpty) l.pfGroupOther,
    ];
    if (!_collapseInitialized) {
      _collapseInitialized = true;
      // A long list opens collapsed (headers + subtotals only); a short list
      // stays fully expanded.
      if (accounts.length > _longListThreshold) {
        _collapsed.addAll(groupTitles);
      }
    }

    final showControls =
        accounts.length >= _longListThreshold || _hideZero || _search.isNotEmpty;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(pad),
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
            if (showControls) ...[
              _buildFilterControls(context, l),
              const SizedBox(height: 16),
            ],
            if (visibleAccounts.isEmpty)
              _buildNoMatches(context, l)
            else
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

  /// Search box + "hide $0" filter chip. Shown only once the list is long
  /// enough to be worth filtering (or while a filter is already active).
  Widget _buildFilterControls(BuildContext context, AppLocalizations l) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 40,
            child: TextField(
              controller: _searchCtl,
              onChanged: (v) => setState(() => _search = v),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: l.pfSearchAccounts,
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: l.pfClearFilters,
                        onPressed: () => setState(() {
                          _searchCtl.clear();
                          _search = '';
                        }),
                      ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilterChip(
          label: Text(l.pfHideZero),
          selected: _hideZero,
          onSelected: (v) => setState(() => _hideZero = v),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// Shown when search / hide-zero filter out every account.
  Widget _buildNoMatches(BuildContext context, AppLocalizations l) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 36, color: context.textFaint),
            const SizedBox(height: 8),
            Text(
              l.pfNoAccountMatches,
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => setState(() {
                _searchCtl.clear();
                _search = '';
                _hideZero = false;
              }),
              child: Text(l.pfClearFilters),
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

    // Native split of this group's total by currency — so e.g. Cash shows how
    // much is genuinely USD vs MXN, not just the converted headline.
    final byCurrency = <String, double>{};
    for (final acc in groupAccounts) {
      final cur = (acc['currency'] ?? targetCurrency).toString().toUpperCase();
      byCurrency[cur] = (byCurrency[cur] ?? 0) +
          ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    }

    // Long lists default to collapsed; an active search force-expands every
    // group so matches are visible without hunting through headers.
    final collapsed =
        _search.trim().isEmpty ? _collapsed.contains(title) : false;
    void toggle() => setState(() {
          if (_collapsed.contains(title)) {
            _collapsed.remove(title);
          } else {
            _collapsed.add(title);
          }
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
          // A4 (round 3, a11y): the collapse header announces as ONE
          // button — "Cash, 3 accounts, $12,345.00" with an
          // expand/collapse hint — instead of a label-less tappable
          // followed by loose text fragments (canonical row shape:
          // MergeSemantics + Semantics(button) > InkWell > Exclude).
          MergeSemantics(
            child: Semantics(
            button: true,
            label: AppLocalizations.of(context).axGroupAccounts(
              title,
              groupAccounts.length,
              currencyFormat.format(total),
            ),
            hint: collapsed
                ? AppLocalizations.of(context).axTapToExpand
                : AppLocalizations.of(context).axTapToCollapse,
            child: InkWell(
            onTap: toggle,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: ExcludeSemantics(
            child: LayoutBuilder(
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
                '$title · ${groupAccounts.length}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
              final chevron = Icon(
                collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 20,
                color: context.textSubtle,
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

              // Left inset that lines the subtitle / currency pills up with
              // the title text's left edge in the header Row:
              // chevron (20) + gap (4) + icon chip (8 + 18 + 8) + gap (12).
              const subLeft = 70.0;

              // Only worth showing when the group spans >1 currency. Each
              // currency reads as its own self-labelled pill ("USD 9,591.00")
              // — never a bare "$" that's ambiguous in a mixed list — and a
              // foreign currency also shows what it's worth in the reporting
              // currency ("≈ $3,238") so the pills visibly add up to the
              // converted headline above them.
              final targetUpper = targetCurrency.toUpperCase();
              final currencyEntries = byCurrency.entries.toList()
                ..sort((a, b) {
                  double conv(MapEntry<String, double> e) => convertCurrency(
                        e.value,
                        from: e.key,
                        to: targetCurrency,
                        usdMxnRate: usdMxnRate,
                      );
                  return conv(b).compareTo(conv(a));
                });
              final currencyLine = byCurrency.length < 2
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 8, left: subLeft),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: currencyEntries.map((e) {
                          final isTarget = e.key == targetUpper;
                          final converted = convertCurrency(
                            e.value,
                            from: e.key,
                            to: targetCurrency,
                            usdMxnRate: usdMxnRate,
                          );
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: context.tileSurface,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: context.hairline),
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text:
                                        formatCurrencyWithCode(e.value, e.key),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: context.textSubtle,
                                    ),
                                  ),
                                  if (!isTarget)
                                    TextSpan(
                                      text:
                                          '  ≈ ${currencyFormat.format(converted)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w400,
                                        color: context.textFaint,
                                      ),
                                    ),
                                ],
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    );

              final subtitleText = subtitle == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 4, left: subLeft),
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
                          chevron,
                          const SizedBox(width: 4),
                          headerIcon,
                          const SizedBox(width: 12),
                          Expanded(child: titleText),
                        ],
                      ),
                      ?subtitleText,
                      ?currencyLine,
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
                        chevron,
                        const SizedBox(width: 4),
                        headerIcon,
                        const SizedBox(width: 12),
                        Expanded(child: titleText),
                        const SizedBox(width: 12),
                        // Cap the total so a pathological value truncates
                        // (it has maxLines/ellipsis) instead of overflowing.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth * 0.4),
                          child: totalText,
                        ),
                      ],
                    ),
                    ?subtitleText,
                    ?currencyLine,
                  ],
                ),
              );
            },
            ),
            ),
            ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 160),
            sizeCurve: Curves.easeOut,
            crossFadeState:
                collapsed ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Divider(color: context.hairline, height: 1),
                ..._renderAccountsWithVaults(context, groupAccounts),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Group accounts by (institution, account_type) within an already
  /// type-filtered group. When a cluster has multiple accounts (e.g. SoFi
  /// Savings + its vaults), pick the dominant one (largest balance) as the
  /// "primary" and render the rest nested below it as sub-accounts.
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
        // sub-accounts collapsed beneath it (tap to expand). The cluster
        // header already carries the combined total, so the summary line
        // below it stays total-free instead of repeating the same figure.
        widgets.add(_buildVaultClusterHeader(context, cluster));
        widgets.add(_CollapsibleVaults(
          label: _subgroupLabel(context, cluster.first),
          count: cluster.length,
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
      // Vault total folded into the attach product's NATIVE currency, so its
      // headline reads as savings + vaults combined.
      final attachAcc = products[attachIdx];
      final attachCur = (attachAcc['currency'] ?? targetCurrency).toString();
      final vaultExtra = vaults.fold<double>(
        0.0,
        (s, v) =>
            s +
            convertCurrency(
              ((v['current_balance'] ?? 0.0) as num).toDouble().abs(),
              from: (v['currency'] ?? targetCurrency).toString(),
              to: attachCur,
              usdMxnRate: usdMxnRate,
            ),
      );
      // Build the bank's account rows (products, with their vaults nested)
      // into `inner`, then fold the whole institution behind ONE collapsible
      // summary header (bank · N accounts · combined total). A bank with two
      // products (e.g. SoFi Checking + Savings, Revolut Cuenta + Savings) then
      // reads as a single compact line that expands on tap.
      final inner = <Widget>[];
      final vaultsLabel =
          vaults.isEmpty ? null : _subgroupLabel(context, vaults.first);
      for (var i = 0; i < products.length; i++) {
        final isAttach = i == attachIdx && vaults.isNotEmpty;
        inner.add(_buildAccountRow(
          context,
          products[i],
          vaultExtraNative: isAttach ? vaultExtra : null,
          vaultCount: isAttach ? vaults.length : null,
          vaultLabel: isAttach ? vaultsLabel : null,
          nested: true,
        ));
        if (isAttach) {
          inner.add(_CollapsibleVaults(
            label: vaultsLabel!,
            count: vaults.length,
            rows: vaults.map((v) => _buildVaultRow(context, v)).toList(),
          ));
        }
      }

      // Combined headline: native figure when the bank is single-currency
      // (reads the way the user thinks of it — Revolut in MXN), else the
      // target-converted total when it mixes currencies.
      final curs = cluster
          .map((a) => (a['currency'] ?? targetCurrency).toString().toUpperCase())
          .toSet();
      final nativeSum = cluster.fold<double>(0.0,
          (s, a) => s + ((a['current_balance'] ?? 0.0) as num).toDouble().abs());
      final convSum = cluster.fold<double>(
        0.0,
        (s, a) =>
            s +
            convertCurrency(
              ((a['current_balance'] ?? 0.0) as num).toDouble().abs(),
              from: (a['currency'] ?? targetCurrency).toString(),
              to: targetCurrency,
              usdMxnRate: usdMxnRate,
            ),
      );
      widgets.add(_CollapsibleInstitution(
        institution: inst,
        countLabel: '${cluster.length} ${l.txAccounts.toLowerCase()}',
        totalLabel: curs.length == 1
            ? formatCurrencyAmount(nativeSum, curs.first)
            : currencyFormat.format(convSum),
        rows: inner,
      ));
    }
    return widgets;
  }

  /// Label for a collapsed sub-group of sibling sub-accounts, derived from
  /// what the accounts actually ARE rather than a hardcoded "Vaults": credit
  /// products are card products ("Cards" — a Chase Sapphire is not a vault),
  /// cash sub-accounts are true savings buckets ("Vaults"), and anything
  /// else falls back to the neutral "Accounts".
  String _subgroupLabel(BuildContext context, dynamic acc) {
    final l = AppLocalizations.of(context);
    return switch (categorizeAccount((acc['account_type'] ?? '').toString())) {
      AccountCategory.credit => l.pfCards,
      AccountCategory.cash => l.pfVaults,
      _ => l.txAccounts,
    };
  }

  /// Header for a cluster of sibling sub-accounts that has no real parent
  /// account. Labels the group by institution + the sub-group descriptor
  /// (Vaults / Cards / Accounts) with the combined total — instead of
  /// borrowing one sub-account's name (which read as a credit-card account).
  Widget _buildVaultClusterHeader(BuildContext context, List<dynamic> cluster) {
    final inst = (cluster.first['institution_name'] ?? '').toString();
    final l = AppLocalizations.of(context);
    final descriptor = _subgroupLabel(context, cluster.first);
    final total = cluster.fold<double>(0.0, (sum, acc) {
      final bal = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
      final cur = (acc['currency'] ?? targetCurrency).toString();
      return sum +
          convertCurrency(bal,
              from: cur, to: targetCurrency, usdMxnRate: usdMxnRate);
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(
                inst.isEmpty
                    ? descriptor
                    : l.pfInstDescriptor(inst, descriptor),
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
            // Cap the total so a pathological value truncates (it has
            // maxLines/ellipsis) instead of overflowing — as a non-flex
            // Row child it would otherwise get unbounded width.
            ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
              child: Text(
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
            ),
            // Mirrors the account rows' menu-button slot so this total
            // right-aligns with the row balances.
            const SizedBox(width: _kTrailingSlotWidth),
          ],
        ),
      ),
    );
  }

  /// Compact sub-row for SoFi-style "vaults". Smaller muted type, no
  /// institution label (it's implied from the parent above), no chevron; a
  /// dash marker in the left gutter is the only nesting affordance so the
  /// name and balance stay in the shared row columns.
  Widget _buildVaultRow(BuildContext context, dynamic acc) {
    final l = AppLocalizations.of(context);
    final balance =
        ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    final sourceCurrency = (acc['currency'] ?? targetCurrency).toString();
    final name = (acc['name'] ?? l.pfVault).toString();

    // One labelled button node per nested sub-account row — the row's
    // Texts alone weren't announced as an activatable unit (leftover c).
    return Semantics(
      button: true,
      label: _accountRowSemanticsLabel(
          l, name, formatCurrencyAmount(balance, sourceCurrency)),
      hint: l.ovwOpensAccountDetails,
      child: InkWell(
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
      child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
        child: Row(
          children: [
            // Dash marker tucked inside the 16px gutter (4 + 8 + 4) so the
            // vault name starts in the same column as account rows.
            Container(
              width: 8,
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: context.hairline,
            ),
            Expanded(
              child: maskAwareNameText(
                name,
                TextStyle(
                  fontSize: 13,
                  color: context.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatCurrencyAmount(balance, sourceCurrency),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            // Mirrors the account rows' menu-button slot so vault
            // balances right-align with the row balances above them.
            const SizedBox(width: _kTrailingSlotWidth),
          ],
        ),
      ),
      ),
      ),
    );
  }

  /// One row inside an account group. Lays out two ways depending on the
  /// available width so the balance never overflows on narrow screens:
  ///   wide  : name+inst — — — — — — balance + companion + menu
  ///   narrow: name+inst stacked, balance below on its own line
  /// [vaultExtraNative] (in the account's native currency) and [vaultCount],
  /// when set, fold a parent account's nested vaults INTO its displayed total —
  /// so "SoFi Savings" reads as the combined savings + vaults figure, with the
  /// base balance shown on the sub-line.
  Widget _buildAccountRow(
    BuildContext context,
    dynamic acc, {
    double? vaultExtraNative,
    int? vaultCount,
    // Localized label for the nested sub-accounts folded into this row's
    // total ("vaults" / "cards" / "accounts"); pairs with [vaultCount].
    String? vaultLabel,
    // True when the row is rendered inside a collapsed institution group: the
    // bank name already sits in the group header, so we drop the per-row
    // institution sub-label to cut the left-side density.
    bool nested = false,
  }) {
    final l = AppLocalizations.of(context);
    final base = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
    final balance = base + (vaultExtraNative ?? 0.0);
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

    // One line keeps every row the same height so the name and balance
    // columns stay aligned; the Tooltip reveals the full name, and a
    // trailing ••mask survives truncation via maskAwareNameText.
    Widget primaryName = Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 600),
      child: maskAwareNameText(
        name,
        TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: context.textPrimary,
        ),
      ),
    );

    // Drop the institution sub-label when it's redundant: nested under a bank
    // header, or the account name already conveys the bank — "Banamex" at
    // institution "Banamex" was reading as a tense "Banamex / Banamex" stack.
    final nameLc = name.toLowerCase();
    final instLc = inst.toLowerCase();
    final nameConveysInst = inst.isNotEmpty &&
        (nameLc == instLc ||
            (instLc.length >= 3 && nameLc.contains(instLc)) ||
            (nameLc.length >= 3 && instLc.contains(nameLc)));
    Widget secondaryMeta = (inst.isEmpty || nested || nameConveysInst)
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
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    Widget? subBalance;
    if (vaultExtraNative != null && vaultExtraNative > 0) {
      // "$50.16 base + 6 vaults" — makes clear the headline figure is the
      // savings base enhanced by the vaults, with the base called out.
      subBalance = Text(
        '${formatCurrencyAmount(base, sourceCurrency)} ${l.pfBase} '
        '+ ${vaultCount ?? 0} ${(vaultLabel ?? l.pfVaults).toLowerCase()}',
        style: TextStyle(
          fontSize: 11,
          color: context.textFaint,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else if (hasCrypto) {
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
          fontFeatures: const [FontFeature.tabularFigures()],
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
      // Name-carrying tooltip doubles as the semantic label, so a screen
      // reader hears WHICH account's menu this is (leftover c).
      tooltip: l.ovwAccountActionsFor(name),
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
      // Each item's icon+text Row is merged into ONE semantics node so the
      // platform announces the action name, not an unlabeled icon + text
      // fragment pair (leftover c).
      itemBuilder: (context) => [
        if (onRenameAccount != null)
          PopupMenuItem(
            value: 'rename',
            child: MergeSemantics(
              child: Row(
                children: [
                  Icon(Icons.drive_file_rename_outline,
                      size: 18, color: context.textMuted),
                  const SizedBox(width: 8),
                  Text(l.pfRename),
                ],
              ),
            ),
          ),
        if (isManualAsset && onRevalueAccount != null)
          PopupMenuItem(
            value: 'revalue',
            child: MergeSemantics(
              child: Row(
                children: [
                  Icon(Icons.price_change_outlined,
                      size: 18, color: context.textMuted),
                  const SizedBox(width: 8),
                  Text(l.pfRevalue),
                ],
              ),
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          child: MergeSemantics(
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
        ),
      ],
    );
    // Pin the button to the shared trailing-slot width: on desktop/web the
    // ThemeData defaults (shrinkWrap tap targets + compact density) shrink
    // it to ~32px, which would knock the balance column ~16px out of line
    // with the header/vault spacers. The height cap keeps the icon level
    // with the row's first text line under the CrossAxisAlignment.start
    // layouts below — a full 48px-tall button sags ~14px on single-line
    // rows — while the 48px-wide slot keeps the tap target comfortable.
    menuButton = SizedBox(
      width: _kTrailingSlotWidth,
      height: 20,
      child: Center(child: menuButton),
    );

    // One labelled button node per account row (name + balance), with the
    // rendered Texts excluded below so nothing is announced twice; the
    // actions menu stays its own focusable node (leftover c).
    return Semantics(
      button: true,
      label: _accountRowSemanticsLabel(l, name, nativeText),
      hint: l.ovwOpensAccountDetails,
      child: InkWell(
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
              padding: const EdgeInsets.fromLTRB(16, 13, 8, 13),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ExcludeSemantics(
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
                  ),
                  menuButton,
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 8, 13),
            child: Row(
              // .start (like the narrow layout) keeps the name's first line
              // level with the balance even when only one side has a sub-line.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [primaryName, secondaryMeta],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
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
        },
      ),
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
/// one summary line — "Vaults · N" — that expands to the individual rows on
/// tap, so a bank with several buckets doesn't consume several rows. The
/// combined total lives on the header above (parent account row or vault
/// cluster header), never here, so the same figure isn't stacked twice.
class _CollapsibleVaults extends StatefulWidget {
  final String label;
  final int count;
  final List<Widget> rows;

  const _CollapsibleVaults({
    required this.label,
    required this.count,
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
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A4 (round 3, a11y): the toggle is a button whose visible text
          // ("Vaults · 3") merges in as its label, with an expand/collapse
          // hint; the chevron carries no semantics.
          MergeSemantics(
            child: Semantics(
            button: true,
            hint: _open
                ? AppLocalizations.of(context).axTapToCollapse
                : AppLocalizations.of(context).axTapToExpand,
            child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              // Same L/R padding as _buildAccountRow so the label shares the
              // rows' 16px name column and the total shares their right edge.
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.label} · ${widget.count}',
                      // Same 13px size as the vault cluster header / vault
                      // rows; the lighter weight + muted color mark it as a
                      // nested summary rather than a bank-level header.
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: context.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Chevron in the same trailing slot as the account rows'
                  // menu button, keeping the total column aligned.
                  SizedBox(
                    width: _kTrailingSlotWidth,
                    child: Icon(
                        _open ? Icons.expand_more : Icons.chevron_right,
                        size: 18,
                        color: context.textSubtle),
                  ),
                ],
              ),
            ),
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

/// Collapses a single institution's multiple accounts behind one summary
/// header (bank · N accounts · combined total). Collapsed by default so a
/// bank with several products/vaults reads as one compact line; tap to
/// expand the individual account rows (which keep their own vault nesting).
class _CollapsibleInstitution extends StatefulWidget {
  final String institution;
  final String countLabel;
  final String totalLabel;
  final List<Widget> rows;

  const _CollapsibleInstitution({
    required this.institution,
    required this.countLabel,
    required this.totalLabel,
    required this.rows,
  });

  @override
  State<_CollapsibleInstitution> createState() =>
      _CollapsibleInstitutionState();
}

class _CollapsibleInstitutionState extends State<_CollapsibleInstitution> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final name =
        widget.institution.isEmpty ? l.pfUnknownAccount : widget.institution;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A4 (round 3, a11y): one button node — "Chase, 3 accounts,
        // $5,000.00" (name/count/total texts merge in) — with an
        // expand/collapse hint; the chevron carries no semantics.
        MergeSemantics(
          child: Semantics(
          button: true,
          hint: _open ? l.axTapToCollapse : l.axTapToExpand,
          child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            // Same L/R padding as _buildAccountRow so the bank name shares
            // the account rows' 16px name column.
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.countLabel,
                          style: TextStyle(
                              fontSize: 12, color: context.textSubtle),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Cap the total so a pathological value truncates (it has
                  // maxLines/ellipsis) instead of overflowing — as a non-flex
                  // Row child it would otherwise get unbounded width.
                  ConstrainedBox(
                    constraints:
                        BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
                    child: Text(
                      widget.totalLabel,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Chevron lives in the same trailing slot as the account
                  // rows' menu button, so the total right-aligns exactly with
                  // the row balances.
                  SizedBox(
                    width: _kTrailingSlotWidth,
                    child: Icon(
                        _open ? Icons.expand_more : Icons.chevron_right,
                        size: 20, color: context.textSubtle),
                  ),
                ],
              ),
            ),
          ),
          ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOut,
          crossFadeState:
              _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          // The nested rows keep the exact same name/balance columns as
          // single-account rows; a hairline guide rail tucked inside their
          // 16px left gutter is the only nesting affordance.
          secondChild: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.rows,
                ),
                Positioned(
                  left: 7,
                  top: 2,
                  bottom: 2,
                  child: IgnorePointer(
                    child: Container(width: 1.5, color: context.hairline),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
