import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/typography.dart';
import '../utils/category.dart';
import '../utils/category_style.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/merchant_total.dart';
import '../utils/theme_colors.dart';
import '../utils/transaction_display.dart';
import '../utils/transactions_tab_logic.dart';
import 'account_mover.dart';

/// The surface [TransactionDetailPanel] needs from its hosting
/// transactions tab.
///
/// Exists because of the 2026-08-03 decoupling: the panel used to take the
/// whole tab `State` (`state: this`) and reach back into 14 of its private
/// members, which welded ~955 panel lines into the transactions_tab god
/// file forever. This interface names exactly what the panel consumes —
/// the shared formatting/build helpers, the single-source category
/// suggestion hub, the tab-owned action flows (split/edit dialogs, rename,
/// the deferred-delete/Undo buffer) and the live widget configuration — so
/// the panel can live in its own file without duplicating any tab logic.
/// [TransactionsTabState] implements it with thin delegates; every helper
/// stays single-source in the tab, where its other call sites keep using
/// the private original.
abstract class TransactionDetailHost {
  // -- Live tab configuration ------------------------------------------
  // Getters (not constructor-captured values) on purpose: the panel
  // rebuilds while open (keyboard insets, theme changes) and must see the
  // tab's CURRENT widget configuration — e.g. the transactions list after
  // a rename refresh — exactly as it did when it read `state.widget.*`.

  /// Reporting currency the converted amounts are shown in.
  String get targetCurrency;

  /// Current USD/MXN rate (0 disables conversion).
  double get usdMxnRate;

  /// Reporting-currency formatter shared with the rest of the tab.
  NumberFormat get currencyFormat;

  /// The currently loaded transaction rows (for merchant matches).
  List<dynamic> get transactions;

  /// Accounts available to the move-account flow.
  List<dynamic> get accounts;

  /// Non-null when the host can open the manual-edit dialog.
  ApiService? get apiService;

  /// Per-transaction update callback; null hides edit/move affordances.
  Function(
    String id, {
    String? userCategory,
    String? userNotes,
    String? userDescription,
    String? accountId,
  })?
  get onUpdate;

  /// Split callback; null hides the split actions.
  Future<void> Function(String parentId, List<Map<String, dynamic>> splits)?
  get onSplitTransaction;

  /// Un-split callback; null hides the unsplit action.
  Future<void> Function(String parentId)? get onUnsplitTransaction;

  /// Delete callback; null hides the delete action. The actual delete is
  /// routed through [deferredDeleteSingle], never called directly, so the
  /// panel's delete shares the tab's one Undo buffer.
  Future<void> Function(String id)? get onDelete;

  /// "Create loan from this transaction"; null hides the action.
  void Function(dynamic tx)? get onCreateLoanFromTx;

  /// "Make recurring"; null hides the action.
  void Function(dynamic tx)? get onMakeRecurring;

  // -- Shared formatting / build helpers --------------------------------

  /// Distinct prettified category labels — the SAME list the bulk-
  /// categorize, split and add-transaction dialogs feed from, so the
  /// panel's type-ahead can't drift into a second divergent taxonomy.
  List<String> distinctCategories();

  /// Account label with its owning institution prefixed.
  String accountLabel(dynamic tx);

  /// Uppercased section heading, shared with the tab's own sections.
  Widget sectionLabel(String label);

  /// Equal-weight icon+label pill for the provenance/channel cloud.
  Widget metaChip(IconData icon, String label);

  /// Localized label for a row's `source` ("plaid" / "csv" / "manual").
  String sourceLabel(BuildContext context, String source);

  /// Icon for Plaid's `payment_channel`.
  IconData channelIcon(String channel);

  /// Sentence-cases a raw enum-ish string ("in store" → "In store").
  String sentenceCase(String s);

  /// Compact date · account · amount row for "Recent at this merchant".
  Widget similarRow(dynamic tx);

  /// Linked cross-currency transfer block ([] when the tx isn't linked).
  List<Widget> fxTransferBlock(String txId);

  // -- Tab-owned action flows --------------------------------------------

  /// Opens the Add-transaction dialog in EDIT mode for a manual row.
  void openEditManualDialog(dynamic tx);

  /// Opens the split editor for a parent [tx].
  Future<void> openSplitDialog(
    dynamic tx,
    String sourceCurrency,
    double sourceAmount,
    String parentLabel,
    String parentCategory,
  );

  /// Opens the split editor pre-filled with an existing split's children.
  Future<void> openEditSplitDialog(
    String parentId,
    String childCurrency,
    double childAmount,
    String parentLabel,
    String parentCategory,
  );

  /// Rename (display label) dialog, optionally applied to similar rows.
  Future<void> renameTransaction(
    dynamic tx, {
    required List<String> similarIds,
  });

  /// Single-row deferred delete: hides the row now, offers Undo, commits
  /// through the tab's one deferred-delete buffer.
  void deferredDeleteSingle(dynamic id, AppLocalizations l);

  // -- Tab lifetime -------------------------------------------------------
  // Deliberately the TAB's `context`/`mounted`, NOT the panel's: the
  // post-close flows (unsplit, move) close the panel and then show their
  // success/failure SnackBars — by that time the panel's own context is
  // defunct, and the SnackBar must live on the tab, which survives the
  // dismissal. `State` already provides both, so the tab implements them
  // for free.

  /// The tab's [BuildContext] (outlives the dismissed panel).
  BuildContext get context;

  /// The tab's `mounted` (guards the post-close SnackBars).
  bool get mounted;
}

/// Stateful body of the transaction detail / edit panel.
///
/// Owns the editor controllers + focus node (and disposes them — the
/// once-inline `showGeneralDialog` builder created them in a method and
/// never freed them, leaking on every open) and the "More details"
/// disclosure state. Reaches its hosting tab exclusively through
/// [TransactionDetailHost] for the shared helpers (`fxTransferBlock`,
/// `metaChip`, `renameTransaction`, the split/move flows, the suggestion
/// list, …) and the live tab configuration, so the editing behaviour is
/// the same as when it lived inside transactions_tab.dart — only the
/// coupling seam changed.
class TransactionDetailPanel extends StatefulWidget {
  final TransactionDetailHost host;
  final dynamic tx;
  // Narrow = bottom sheet (mobile); wide = right-docked side panel
  // (desktop/web). Drives the dismiss affordance: drag handle + swipe on
  // narrow, top-right X on wide.
  final bool isNarrow;

  const TransactionDetailPanel({
    super.key,
    required this.host,
    required this.tx,
    required this.isNarrow,
  });

  @override
  State<TransactionDetailPanel> createState() => _TransactionDetailPanelState();
}

class _TransactionDetailPanelState extends State<TransactionDetailPanel> {
  late final TextEditingController _catController;
  late final FocusNode _catFocusNode;
  late final TextEditingController _notesController;

  late final String _initialCategoryLabel;
  late final String _initialNotes;
  late final List<String> _categorySuggestions;

  TransactionDetailHost get _host => widget.host;
  dynamic get tx => widget.tx;

  @override
  void initState() {
    super.initState();
    // Prefill the category editor with the PRETTIFIED label — the same
    // string the list row shows — never the raw Plaid enum
    // ("FOOD_AND_DRINK"). The Save handler diffs the field against this
    // exact prefill (see [diffEditedField]), so open-then-Save with no
    // edits sends nothing instead of silently converting the
    // auto-category into a user override of the raw enum string.
    final hasAnyCategory =
        (tx['user_category'] ?? '').toString().trim().isNotEmpty ||
        (tx['category'] ?? '').toString().trim().isNotEmpty ||
        (tx['category_detailed'] ?? '').toString().trim().isNotEmpty;
    _initialCategoryLabel = hasAnyCategory
        ? prettyCategory(
            userCategory: tx['user_category']?.toString(),
            detailed: tx['category_detailed']?.toString(),
            primary: tx['category']?.toString(),
          )
        : '';
    _initialNotes = (tx['user_notes'] ?? '').toString();
    _catController = TextEditingController(text: _initialCategoryLabel);
    _catFocusNode = FocusNode();
    _notesController = TextEditingController(text: _initialNotes);
    // Shared suggestion source — the same list the bulk-categorize and
    // add-transaction dialogs feed from, so the type-ahead can't drift
    // into a second divergent taxonomy.
    _categorySuggestions = _host.distinctCategories();
  }

  @override
  void dispose() {
    _catController.dispose();
    _catFocusNode.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Pop the hosting dialog route. Uses the panel's own context so it
  /// targets the showGeneralDialog route regardless of where the host's
  /// context sits in the tree.
  void _close() => Navigator.of(context).pop();

  /// Quiet label → value row for the compact "Details" group. Distinct
  /// from the equal-weight [TransactionDetailHost.metaChip] cloud: the
  /// label is de-emphasised and the value carries the weight, so the
  /// group scans as a small table instead of a pill soup.
  Widget _detailRow(
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
    bool maskAware = false,
  }) {
    final valueStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: valueColor ?? context.textPrimary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: context.textFaint),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: context.textSubtle),
          ),
          const SizedBox(width: 12),
          Expanded(
            // maskAware: single-line, keeps a trailing "••1234" account mask
            // visible under truncation; Align preserves the right-edge fit
            // since maskAwareNameText's Row doesn't stretch.
            child: maskAware
                ? Align(
                    alignment: Alignment.centerRight,
                    child: maskAwareNameText(value, valueStyle),
                  )
                : Text(
                    value,
                    textAlign: TextAlign.end,
                    style: valueStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final host = _host;
    final isNarrow = widget.isNarrow;
    // Vertical rhythm: the phone bottom sheet compacts the big gaps so a
    // typical transaction lands around half-screen; the wide side panel
    // keeps its roomier 18px rhythm.
    final sectionGap = isNarrow ? 12.0 : 18.0;

    final date = DateTime.parse(tx['date'] as String);
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency = (tx['currency'] ?? host.targetCurrency).toString();
    final convertedAmount = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: host.targetCurrency,
      usdMxnRate: host.usdMxnRate,
    );
    final needsConversion =
        host.usdMxnRate > 0 && sourceCurrency != host.targetCurrency;
    // Storage sign convention (backend sync.rs:659): negative = outflow,
    // positive = inflow.
    final isExpense = sourceAmount < 0;
    // ONE accent pair for the binary in/out concept: inflow = jade
    // positive, outflow = neutral text. The red `negative` token stays
    // reserved for destructive affordances; teal for transfer/linked.
    final flowAccent = isExpense ? context.textPrimary : context.positive;
    // Provenance comes only from the payload — an absent/null source
    // renders as the explicit "unknown" state, never assumed 'plaid'
    // (that assumption once stamped "Synced via Plaid" on hand-typed
    // rows).
    final source = (tx['source'] ?? '').toString();
    final originalCategory = (tx['category'] ?? '').toString();
    final merchant = (tx['merchant_name'] ?? '').toString();
    final pending = tx['pending'] == true;
    final rawDescription = (tx['description'] ?? '').toString();
    final titleDescription = displayLabel(tx);
    final logoUrl = counterpartyLogo(tx);
    // Hero icon style — same registry the list rows use, keyed on the
    // prettified label (always non-empty).
    final catStyle = context.categoryStyle(
      prettyCategory(
        userCategory: tx['user_category']?.toString(),
        detailed: tx['category_detailed']?.toString(),
        primary: tx['category']?.toString(),
      ),
    );
    final color = catStyle.color;
    final channel = (tx['payment_channel'] ?? '').toString();

    // All transactions sharing this exact description (excluding the
    // current one). Used for lifetime spend + recent rows.
    final merchantMatches = host.transactions.where((other) {
      if (other['id'] == tx['id']) return false;
      return (other['description'] ?? '').toString().trim().toLowerCase() ==
          rawDescription.trim().toLowerCase();
    }).toList();
    final similar = merchantMatches.take(3).toList();
    // Seeded with the CONVERTED amount — see [merchantLifetimeTotal] for the
    // mixed-currency overstatement this replaced.
    final merchantTotal = merchantLifetimeTotal(
      openConvertedAmount: convertedAmount,
      siblings: merchantMatches,
      targetCurrency: host.targetCurrency,
      usdMxnRate: host.usdMxnRate,
    );
    final merchantCount = merchantMatches.length + 1;

    // Original auto-categorization (Plaid), independent of any user
    // override. Only worth a row when the user HAS overridden it with a
    // different label — otherwise the Category field above already shows
    // the identical prettified string and the row is pure duplication.
    final userCat = (tx['user_category'] ?? '').toString().trim();
    final autoCategoryLabel =
        (originalCategory.isNotEmpty ||
            (tx['category_detailed'] ?? '').toString().isNotEmpty)
        ? prettyCategory(
            detailed: tx['category_detailed']?.toString(),
            primary: tx['category']?.toString(),
          )
        : null;
    final hasChannel = channel.isNotEmpty && channel != 'other';

    // Whether the overflow ("More actions") kebab has anything to show.
    final canMove = host.accounts.isNotEmpty && host.onUpdate != null;
    final isChild = (tx['parent_id'] ?? '').toString().isNotEmpty;
    final canSplit = !isChild && host.onSplitTransaction != null;
    final canEditSplit =
        isChild &&
        host.onSplitTransaction != null &&
        host.onUnsplitTransaction != null;
    final canUnsplit = isChild && host.onUnsplitTransaction != null;
    final canDelete = host.onDelete != null;
    // Only an outflow can fund a loan (money left the account).
    final canCreateLoan = host.onCreateLoanFromTx != null && sourceAmount < 0;
    final canMakeRecurring = host.onMakeRecurring != null;
    // Full edit (amount/date/direction/account/…) — ONLY for hand-typed
    // rows: the user is the source of truth there, whereas synced /
    // imported facts belong to the bank (the server enforces the same
    // rule with a 403). Split children are excluded — their amounts are
    // bound to the parent; that path is the split editor.
    final canEditManual =
        source == 'manual' &&
        !isChild &&
        host.apiService != null &&
        host.accounts.isNotEmpty;
    final hasOverflow =
        canEditManual ||
        canMove ||
        canSplit ||
        canEditSplit ||
        canUnsplit ||
        canCreateLoan ||
        canMakeRecurring ||
        canDelete;

    Widget detailRows() {
      // Date is folded into the hero block, so it is intentionally
      // omitted here to avoid showing it twice.
      final rows = <Widget>[
        if ((tx['account_name'] ?? '').toString().isNotEmpty)
          _detailRow(
            Icons.account_balance,
            l.txAccount,
            host.accountLabel(tx),
            maskAware: true,
          ),
        if (autoCategoryLabel != null &&
            userCat.isNotEmpty &&
            autoCategoryLabel != userCat)
          _detailRow(Icons.label_outline, l.txAutoCategory, autoCategoryLabel),
        if (pending)
          _detailRow(
            Icons.hourglass_empty,
            l.txStatus,
            l.txStatusPending,
            valueColor: context.warning,
          ),
      ];
      if (rows.isEmpty) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: context.tileSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: context.hairline),
              rows[i],
            ],
          ],
        ),
      );
    }

    // Overflow kebab + rename/edit action, shared by both layouts: the
    // wide side panel keeps them in the dedicated header row; the narrow
    // bottom sheet folds them into the hero row (the header row there
    // held only X/kebab/edit, and X duplicates handle/swipe/barrier).
    Widget overflowButton() {
      return PopupMenuButton<String>(
        tooltip: l.txMoreActions,
        icon: const Icon(Icons.more_horiz, size: 22),
        onSelected: (value) {
          switch (value) {
            case 'editManual':
              // Close the detail panel first — the edit rewrites the very
              // fields the panel is showing, so a stale panel behind the
              // dialog would misrepresent the row after save.
              _close();
              host.openEditManualDialog(tx);
              break;
            case 'split':
              host.openSplitDialog(
                tx,
                sourceCurrency,
                sourceAmount,
                titleDescription,
                originalCategory,
              );
              break;
            case 'editSplit':
              host.openEditSplitDialog(
                (tx['parent_id'] ?? '').toString(),
                sourceCurrency,
                sourceAmount,
                titleDescription,
                originalCategory,
              );
              break;
            case 'unsplit':
              _unsplit(l);
              break;
            case 'move':
              _showMoveSheet(l);
              break;
            case 'createLoan':
              _close();
              host.onCreateLoanFromTx?.call(tx);
              break;
            case 'makeRecurring':
              _close();
              host.onMakeRecurring?.call(tx);
              break;
            case 'delete':
              _confirmDelete(l);
              break;
          }
        },
        itemBuilder: (ctx) => [
          if (canEditManual)
            PopupMenuItem(
              value: 'editManual',
              child: _menuRow(Icons.edit_note, l.txEditTransaction),
            ),
          if (canSplit)
            PopupMenuItem(
              value: 'split',
              child: _menuRow(Icons.call_split, l.txSplitThisTransaction),
            ),
          if (canEditSplit)
            PopupMenuItem(
              value: 'editSplit',
              child: _menuRow(Icons.edit_outlined, l.txEditSplit),
            ),
          if (canUnsplit)
            PopupMenuItem(
              value: 'unsplit',
              child: _menuRow(Icons.call_merge, l.txUnsplitRestore),
            ),
          if (canMove)
            PopupMenuItem(
              value: 'move',
              child: _menuRow(
                Icons.drive_file_move_outlined,
                l.txMoveToDifferentAccount,
              ),
            ),
          if (canCreateLoan)
            PopupMenuItem(
              value: 'createLoan',
              child: _menuRow(
                Icons.monetization_on_outlined,
                l.txCreateLoanFromTx,
              ),
            ),
          if (canMakeRecurring)
            PopupMenuItem(
              value: 'makeRecurring',
              child: _menuRow(Icons.autorenew_rounded, l.recMakeRecurring),
            ),
          if (canDelete)
            PopupMenuItem(
              value: 'delete',
              child: _menuRow(
                Icons.delete_outline,
                l.actionDelete,
                color: context.negative,
              ),
            ),
        ],
      );
    }

    Widget editButton() {
      return IconButton(
        tooltip: merchantMatches.isEmpty
            ? l.txRename
            : l.txRenamePlusMatching(merchantMatches.length),
        iconSize: 20,
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => host.renameTransaction(
          tx,
          similarIds: merchantMatches.map((m) => m['id'].toString()).toList(),
        ),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      );
    }

    return Padding(
      // Narrow sheet uses a tighter frame (SafeArea below already covers
      // the home indicator); wide side panel keeps the roomy 24s.
      padding: isNarrow
          ? const EdgeInsets.fromLTRB(20, 8, 20, 12)
          : const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Header chrome ---------------------------------------------
          // Wide (side panel): Close (X) sits on the LEADING (left) edge of
          // the header — on its own, away from the overflow/rename actions
          // on the right, so it unmistakably reads as "close" and sits
          // right next to the scrim a user instinctively clicks; Esc works
          // too. Narrow (bottom sheet): no header row — dismissal is the
          // drag handle / swipe-down / barrier, and the kebab + edit
          // actions ride the hero row instead, saving ~48px of chrome.
          if (isNarrow)
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 250) _close();
                },
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 4, bottom: 12),
                  decoration: BoxDecoration(
                    color: context.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          if (!isNarrow)
            Row(
              children: [
                // Primary dismiss — isolated on the leading edge.
                IconButton(
                  icon: const Icon(Icons.close, size: 22),
                  onPressed: _close,
                  tooltip: l.actionClose,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
                const Spacer(),
                if (hasOverflow) overflowButton(),
                if (host.onUpdate != null) editButton(),
              ],
            ),
          // -- Scrollable body -------------------------------------------
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // -- Hero: logo + title + subtitle -------------------
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: logoUrl != null
                            ? Image.network(
                                logoUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Icon(catStyle.icon, color: color, size: 28),
                              )
                            : Icon(catStyle.icon, color: color, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titleDescription,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Merchant subtitle (only when it adds info
                            // over the title) — the single place the
                            // merchant name appears now (the duplicate
                            // storefront chip was removed).
                            if (merchant.isNotEmpty &&
                                merchant.toLowerCase() !=
                                    titleDescription.toLowerCase()) ...[
                              const SizedBox(height: 2),
                              Text(
                                merchant,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.textSubtle,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // Narrow: the kebab + edit actions ride the hero row
                      // (there is no dedicated header row on the sheet).
                      if (isNarrow) ...[
                        if (hasOverflow) overflowButton(),
                        if (host.onUpdate != null) editButton(),
                      ],
                    ],
                  ),
                  SizedBox(height: sectionGap),
                  // -- Hero amount block -------------------------------
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: isNarrow ? 10 : 16,
                    ),
                    decoration: BoxDecoration(
                      color: context.tint(0.04),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: flowAccent.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              isExpense ? l.txOutflow : l.txInflow,
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.2,
                                color: flowAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            // Date folded into the hero — keeps the
                            // most-glanced fact next to the amount.
                            Text(
                              DateFormat('MMM d, y').format(date),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.textSubtle,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isNarrow ? 2 : 6),
                        Text(
                          '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                          style: brandDisplayStyle(
                            fontSize: isNarrow ? 24 : 32,
                            color: flowAccent,
                          ),
                        ),
                        if (needsConversion) ...[
                          const SizedBox(height: 4),
                          Text(
                            l.txApproxEstimated(
                              host.currencyFormat.format(convertedAmount.abs()),
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: sectionGap),
                  // -- Primary editable: Category then Notes -----------
                  RawAutocomplete<String>(
                    textEditingController: _catController,
                    focusNode: _catFocusNode,
                    optionsBuilder: (TextEditingValue value) {
                      final q = value.text.trim().toLowerCase();
                      if (q.isEmpty) return _categorySuggestions;
                      return _categorySuggestions.where(
                        (c) => c.toLowerCase().contains(q),
                      );
                    },
                    fieldViewBuilder:
                        (ctx, controller, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              labelText: l.txCategory,
                              hintText: l.txCategoryHint,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => onFieldSubmitted(),
                          );
                        },
                    optionsViewBuilder: (ctx, onSelected, options) {
                      final opts = options.toList();
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxHeight: 200,
                              maxWidth: 420,
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: opts.length,
                              itemBuilder: (ctx, index) {
                                final option = opts[index];
                                return InkWell(
                                  onTap: () => onSelected(option),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Text(option),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    decoration: InputDecoration(
                      labelText: l.txNotes,
                      hintText: l.txNotesHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    minLines: 1,
                    maxLines: 4,
                  ),
                  SizedBox(height: isNarrow ? 12 : 16),
                  // -- Compact Details group ---------------------------
                  detailRows(),
                  // -- Linked FX transfer (inline, high-signal) --------
                  ...host.fxTransferBlock(tx['id']?.toString() ?? ''),
                  // -- More details disclosure -------------------------
                  const SizedBox(height: 12),
                  Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      title: Text(
                        l.txMoreDetails,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                      children: [
                        if (rawDescription != titleDescription) ...[
                          // Manual rows hold the user's own words, not
                          // bank data — neutral copy, not "raw bank text".
                          host.sectionLabel(
                            source == 'manual'
                                ? l.txOriginalText
                                : l.txRawBankText,
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            rawDescription,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textMuted,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            // Icon mirrors provenance: hand-typed rows
                            // get a pencil, imports a file, synced rows
                            // the cloud — a cloud on a manual row would
                            // re-assert the "synced" claim the label
                            // just corrected.
                            host.metaChip(switch (source) {
                              'manual' => Icons.edit_outlined,
                              'csv' => Icons.upload_file_outlined,
                              'plaid' => Icons.cloud_download,
                              _ => Icons.help_outline,
                            }, host.sourceLabel(context, source)),
                            if (hasChannel)
                              host.metaChip(
                                host.channelIcon(channel),
                                host.sentenceCase(channel.replaceAll('_', ' ')),
                              ),
                          ],
                        ),
                        if (similar.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          host.sectionLabel(l.txRecentAtMerchant),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              l.txMerchantTotal(
                                host.currencyFormat.format(merchantTotal),
                                merchantCount,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: context.textMuted,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          ...similar.map((other) => host.similarRow(other)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          // -- Footer: one unambiguous primary commit -------------------
          // Dismissal is owned by the chrome — X / Esc / barrier (desktop),
          // drag handle / swipe-down / barrier (mobile) — so the old
          // secondary "Close" next to Save (which read as cancel-vs-save but
          // never actually reverted) is gone. SafeArea keeps Save clear of
          // the home indicator on mobile.
          //
          // Save only appears once a field is actually dirty (diffed with
          // the same helper the handler uses), so a read-only open shows
          // no footer at all. Dismissal still discards — deliberately NOT
          // commit-on-dismiss.
          ListenableBuilder(
            listenable: Listenable.merge([_catController, _notesController]),
            builder: (context, _) {
              final dirty =
                  diffEditedField(_catController.text, _initialCategoryLabel) !=
                      null ||
                  diffEditedField(_notesController.text, _initialNotes) != null;
              if (!dirty) {
                // Keep the home-indicator inset even without the button.
                return SafeArea(
                  top: false,
                  bottom: isNarrow,
                  child: const SizedBox.shrink(),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  SafeArea(
                    top: false,
                    bottom: isNarrow,
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          // Diff each field against its prefill: only what
                          // the user actually edited is sent (null = "leave
                          // alone").
                          final newCategory = diffEditedField(
                            _catController.text,
                            _initialCategoryLabel,
                          );
                          final newNotes = diffEditedField(
                            _notesController.text,
                            _initialNotes,
                          );
                          _close();
                          if (newCategory == null && newNotes == null) {
                            return;
                          }
                          host.onUpdate?.call(
                            tx['id'],
                            userCategory: newCategory,
                            userNotes: newNotes,
                          );
                        },
                        child: Text(l.actionSave),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, {Color? color}) {
    final c = color ?? context.textPrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: c)),
      ],
    );
  }

  /// Unsplit via the overflow menu — mirrors the old inline button.
  Future<void> _unsplit(AppLocalizations l) async {
    final onUnsplit = _host.onUnsplitTransaction;
    if (onUnsplit == null) return;
    // Deliberately the HOST's messenger, captured before the async gap
    // (house pattern): the panel route is popped below, so the SnackBar
    // must live on the tab, which survives the dismissal.
    final messenger = ScaffoldMessenger.of(_host.context);
    _close();
    try {
      await onUnsplit((tx['parent_id'] ?? '').toString());
      if (!_host.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l.txSplitRemoved)));
    } catch (e) {
      if (!_host.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.txUnsplitFailed(e.toString()))),
      );
    }
  }

  /// Delete via the overflow menu — confirm dialog then `onDelete`.
  Future<void> _confirmDelete(AppLocalizations l) async {
    if (_host.onDelete == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.txDeleteOneTitle),
        content: Text(l.txDeleteOneBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: ctx.negative),
            child: Text(l.actionDelete),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    _close();
    // Hand the actual delete to the tab's deferred-delete buffer so the
    // row hides immediately and an Undo SnackBar offers a 6s reversal,
    // matching the bulk path. (The detail panel itself is gone by now —
    // the SnackBar + Undo live on the tab's ScaffoldMessenger.)
    if (!_host.mounted) return;
    _host.deferredDeleteSingle(tx['id'], l);
  }

  /// Move-to-account via the overflow menu. Opens a small bottom sheet
  /// hosting the existing [AccountMover] picker (kept verbatim).
  void _showMoveSheet(AppLocalizations l) {
    final host = _host;
    // The HOST's messenger, captured before any async gap: the move
    // failure SnackBar fires after both the sheet and the panel are
    // gone, so it must ride the tab's lifetime.
    final messenger = ScaffoldMessenger.of(host.context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(sheetCtx).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              host.sectionLabel(l.txMoveToDifferentAccount),
              const SizedBox(height: 12),
              AccountMover(
                accounts: host.accounts,
                currentAccountId: tx['account_id']?.toString(),
                onMove: (newAccountId) async {
                  Navigator.pop(sheetCtx);
                  _close();
                  try {
                    await Future.value(
                      host.onUpdate?.call(tx['id'], accountId: newAccountId),
                    );
                  } catch (e) {
                    // Post-close failure surfaces on the TAB (the panel
                    // and sheet are both gone by now).
                    if (!host.mounted) return;
                    messenger.showSnackBar(
                      SnackBar(content: Text(l.txMoveFailed(e.toString()))),
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
