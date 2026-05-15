import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:web/web.dart' as web;
import '../services/api_service.dart';
import '../utils/category.dart';
import '../utils/currency.dart';
import 'add_transaction_dialog.dart';

class TransactionsTab extends StatefulWidget {
  final List<dynamic> transactions;
  final List<dynamic> accounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String id,
      {String? userCategory, String? userNotes, String? accountId})? onUpdate;
  final Future<void> Function(String id)? onDelete;
  /// Optional callback to jump to the Management tab (used by the empty
  /// state's "Go to Management" button). Wired by the dashboard.
  final VoidCallback? onGoToManagement;
  /// ApiService for the "Add transaction" button + CSV export URL.
  /// Optional so consumers that don't need those actions can omit it.
  final ApiService? apiService;
  /// Invoked after a manual transaction has been added so the parent
  /// can refresh its transaction list.
  final VoidCallback? onTransactionAdded;

  const TransactionsTab({
    super.key,
    required this.transactions,
    this.accounts = const [],
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onUpdate,
    this.onDelete,
    this.onGoToManagement,
    this.apiService,
    this.onTransactionAdded,
  });

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  String _searchQuery = '';
  bool _searchOpenOnNarrow = false;

  List<dynamic> get _filteredTransactions {
    if (_searchQuery.isEmpty) return widget.transactions;
    final q = _searchQuery.toLowerCase();
    return widget.transactions.where((tx) {
      final desc = (tx['description'] ?? '').toString().toLowerCase();
      final acct = (tx['account_name'] ?? '').toString().toLowerCase();
      final cat = (tx['category'] ?? '').toString().toLowerCase();
      return desc.contains(q) || acct.contains(q) || cat.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.transactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.receipt_long_outlined,
                size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'No transactions yet',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Link a bank, import a statement, or add an account manually\n'
              'to start seeing activity here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: widget.onGoToManagement,
              icon: const Icon(Icons.add_link, size: 18),
              label: const Text('Go to Management'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredTransactions;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LayoutBuilder(builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 560;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildToolbar(isNarrow),
              const SizedBox(height: 8),
              Text(
                'Showing ${filtered.length} of ${widget.transactions.length}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              // Flat list of rows with inline date-group headers
              // (Today / Yesterday / weekday name / "Month d"). Avoids
              // ListView.separated so we can interleave headers between
              // groups without inserting a divider above each header.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildGroupedRows(filtered, isNarrow),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// Header toolbar. On wide screens shows title + inline search. On narrow
  /// screens the search collapses to an icon button that expands into a
  /// full-width input, so the title doesn't fight a 280px search box for
  /// horizontal space.
  Widget _buildToolbar(bool isNarrow) {
    if (isNarrow && _searchOpenOnNarrow) {
      return Row(
        children: [
          Expanded(child: _searchField()),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => setState(() {
              _searchOpenOnNarrow = false;
              _searchQuery = '';
            }),
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Close search',
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Flexible(
          child: Text(
            'Recent transactions',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.apiService != null) ...[
              IconButton(
                onPressed: () => _openAddDialog(),
                icon: const Icon(Icons.add, size: 22),
                tooltip: 'Add transaction',
              ),
              IconButton(
                onPressed: () => _downloadCsv(),
                icon: const Icon(Icons.file_download_outlined, size: 22),
                tooltip: 'Export CSV',
              ),
            ],
            if (isNarrow)
              IconButton(
                onPressed: () =>
                    setState(() => _searchOpenOnNarrow = true),
                icon: const Icon(Icons.search, size: 20),
                tooltip: 'Search transactions',
              )
            else
              SizedBox(width: 280, height: 40, child: _searchField()),
          ],
        ),
      ],
    );
  }

  void _openAddDialog() {
    if (widget.apiService == null) return;
    showDialog(
      context: context,
      builder: (_) => AddTransactionDialog(
        accounts: widget.accounts,
        apiService: widget.apiService!,
        onCreated: () => widget.onTransactionAdded?.call(),
      ),
    );
  }

  void _downloadCsv() {
    if (widget.apiService == null) return;
    // Hand off to the browser — the backend responds with
    // Content-Disposition: attachment so the browser downloads directly.
    web.window.open(widget.apiService!.exportTransactionsCsvUrl(), '_self');
  }

  Widget _searchField() {
    return TextField(
      autofocus: _searchOpenOnNarrow,
      onChanged: (v) => setState(() => _searchQuery = v),
      decoration: InputDecoration(
        hintText: 'Search transactions…',
        hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
        prefixIcon:
            const Icon(Icons.search, size: 18, color: Colors.white30),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  /// Group the filtered transactions into Today / Yesterday / weekday /
  /// "Month d" sections so a long scroll is scannable. Hairline dividers
  /// sit *between* rows within a group but not above the header — that's
  /// why we hand-roll the list instead of using ListView.separated.
  List<Widget> _buildGroupedRows(List<dynamic> txs, bool isNarrow) {
    final out = <Widget>[];
    String? lastGroup;
    for (var i = 0; i < txs.length; i++) {
      final tx = txs[i];
      final dateStr = tx['date'] as String?;
      if (dateStr == null) continue;
      final date = DateTime.parse(dateStr);
      final key = _dateGroupKey(date);
      if (key != lastGroup) {
        out.add(_dateGroupHeader(date, isFirst: lastGroup == null));
        lastGroup = key;
      } else {
        out.add(const Divider(
          height: 1,
          thickness: 1,
          color: Colors.white10,
          indent: 44, // align with the description column, past the icon
        ));
      }
      out.add(_buildTransactionRow(tx, isNarrow));
    }
    return out;
  }

  /// Stable key for grouping. "today" / "yesterday" / yyyy-mm-dd otherwise.
  String _dateGroupKey(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'yesterday';
    return '${date.year}-${date.month}-${date.day}';
  }

  /// Section heading shown above each date group. Reads "Today" /
  /// "Yesterday" / weekday for the past week, then "Month d" / "Month d,
  /// yyyy" for older dates.
  Widget _dateGroupHeader(DateTime date, {required bool isFirst}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    String label;
    if (diff == 0) {
      label = 'Today';
    } else if (diff == 1) {
      label = 'Yesterday';
    } else if (diff > 1 && diff < 7) {
      label = DateFormat('EEEE').format(date);
    } else if (date.year == now.year) {
      label = DateFormat('MMM d').format(date);
    } else {
      label = DateFormat('MMM d, y').format(date);
    }
    return Padding(
      padding: EdgeInsets.only(
        top: isFirst ? 4 : 18,
        bottom: 6,
        left: 4,
        right: 4,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white54,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  /// One row in the transactions list. Modern dense layout — 32px icon,
  /// single-line description + meta, right-aligned native-currency amount.
  /// Total row height is ~56px (was 92), so a wall of transactions
  /// actually feels like a scannable list instead of an inbox of cards.
  Widget _buildTransactionRow(dynamic tx, bool isNarrow) {
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final converted = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final isExpense = sourceAmount > 0;
    final category = tx['user_category'] ?? tx['category'];
    final notes = (tx['user_notes'] ?? '').toString();
    final color = _getCategoryColor(category, tx['description']);

    final needsConversion =
        widget.usdMxnRate > 0 && sourceCurrency != widget.targetCurrency;

    return InkWell(
      onTap: () => _showTransactionDetails(tx),
      hoverColor: Colors.white.withValues(alpha: 0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _getCategoryIcon(category, tx['description']),
                color: color,
                size: 16,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _titleCase(tx['description'] ?? 'Unknown'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _metaLine(tx, notes),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Right-aligned amount. Bold native currency on top, optional
            // converted estimate below (desktop only — narrow viewports
            // hide it so the description column has breathing room).
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isNarrow ? 100 : 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: isExpense
                          ? Colors.white
                          : const Color(0xFF00E676),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (needsConversion && !isNarrow)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '≈ ${widget.currencyFormat.format(converted.abs())}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (tx['pending'] == true)
                    Container(
                      margin: const EdgeInsets.only(top: 3),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        'Pending',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact secondary line. The date is now in the group header above,
  /// so we drop it here and surface category instead — keeping the row
  /// to one line of meta even when there's a user note attached. The
  /// category is run through prettyCategory so Plaid's screaming
  /// "LOAN_PAYMENTS" reads as "Loan payment" / "Credit card payment".
  String _metaLine(dynamic tx, String notes) {
    final account = (tx['account_name'] ?? '').toString();
    final cat = prettyCategory(
      userCategory: tx['user_category']?.toString(),
      detailed: tx['category_detailed']?.toString(),
      primary: tx['category']?.toString(),
    );
    final parts = <String>[
      if (cat.isNotEmpty && cat != 'Uncategorized') cat,
      if (account.isNotEmpty) account,
      if (notes.isNotEmpty) notes,
    ];
    return parts.join(' · ');
  }

  /// Detail modal. Layout (top to bottom):
  /// - Close button
  /// - Big category icon + description title
  /// - Hero amount block (target currency, companion currency, in/out)
  /// - Chip row: Date · Account · Source · Pending
  /// - Raw bank description (if differs from title)
  /// - Editable: Category + Notes
  /// - "Recent at this merchant" — up to 3 other transactions matching description
  /// - Save / Close footer
  void _showTransactionDetails(dynamic tx) {
    final catController = TextEditingController(
      text: (tx['user_category'] ?? tx['category'] ?? '').toString(),
    );
    final notesController = TextEditingController(
      text: (tx['user_notes'] ?? '').toString(),
    );

    final date = DateTime.parse(tx['date'] as String);
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final convertedAmount = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final needsConversion =
        widget.usdMxnRate > 0 && sourceCurrency != widget.targetCurrency;
    final isExpense = sourceAmount > 0;
    final source = (tx['source'] ?? 'plaid').toString();
    final originalCategory = (tx['category'] ?? '').toString();
    final merchant = (tx['merchant_name'] ?? '').toString();
    final pending = tx['pending'] == true;
    final rawDescription = (tx['description'] ?? '').toString();
    final titleDescription = _titleCase(rawDescription);
    final color = _getCategoryColor(
      tx['user_category'] ?? tx['category'],
      rawDescription,
    );

    // All transactions sharing this exact description (excluding the
    // current one). We use the full set to compute lifetime spend at
    // this merchant, then take(3) for the visible recent rows.
    final merchantMatches = widget.transactions.where((other) {
      if (other['id'] == tx['id']) return false;
      return (other['description'] ?? '').toString().trim().toLowerCase() ==
          rawDescription.trim().toLowerCase();
    }).toList();
    final similar = merchantMatches.take(3).toList();
    // Lifetime spend at this merchant (including the current tx),
    // converted to the reporting currency. Use the absolute value
    // since incoming/outgoing share a sign convention we don't need
    // to disambiguate in a single rollup.
    final merchantTotal = merchantMatches.fold<double>(
      sourceAmount.abs(),
      (sum, other) {
        final amt = ((other['amount'] as num?)?.toDouble() ?? 0.0).abs();
        final otherCcy = (other['currency'] ?? widget.targetCurrency)
            .toString();
        return sum +
            convertCurrency(
              amt,
              from: otherCcy,
              to: widget.targetCurrency,
              usdMxnRate: widget.usdMxnRate,
            );
      },
    );
    final merchantCount = merchantMatches.length + 1;

    // Slide-from-right side panel on wide screens, bottom-sheet on narrow.
    // This is the Linear / Notion / Gmail pattern — keeps the underlying
    // list visible (in spirit) instead of slamming a centered modal that
    // reads as a full page.
    final size = MediaQuery.sizeOf(context);
    final isNarrow = size.width < 700;

    showGeneralDialog(
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
              width: isNarrow ? size.width : 480,
              height: isNarrow ? size.height * 0.9 : size.height,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A24),
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Close',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          _getCategoryIcon(
                            tx['user_category'] ?? tx['category'],
                            rawDescription,
                          ),
                          color: color,
                          size: 28,
                        ),
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
                            if (merchant.isNotEmpty &&
                                merchant.toLowerCase() !=
                                    titleDescription.toLowerCase()) ...[
                              const SizedBox(height: 2),
                              Text(
                                merchant,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Hero amount block — biggest visual element
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: (isExpense
                                ? Colors.redAccent
                                : const Color(0xFF1DE9B6))
                            .withValues(alpha: 0.25),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isExpense ? 'OUTFLOW' : 'INFLOW',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            color: isExpense
                                ? Colors.redAccent.shade100
                                : const Color(0xFF1DE9B6),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Hero amount in the transaction's NATIVE currency
                        // (this is the real, bank-reported value).
                        Text(
                          '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: isExpense
                                ? Colors.white
                                : const Color(0xFF00E676),
                          ),
                        ),
                        if (needsConversion) ...[
                          const SizedBox(height: 4),
                          Text(
                            '≈ ${widget.currencyFormat.format(convertedAmount.abs())} (estimated)',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Metadata chips
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _metaChip(
                        Icons.event,
                        DateFormat('EEE, MMM d, y').format(date),
                      ),
                      if ((tx['account_name'] ?? '').toString().isNotEmpty)
                        _metaChip(Icons.account_balance,
                            tx['account_name'].toString()),
                      _metaChip(Icons.cloud_download, _sourceLabel(source)),
                      // The auto-classified category, prettified from
                      // Plaid's PFC enum codes. Only shown when the user
                      // hasn't already overridden it with a hand-typed
                      // category.
                      if ((tx['user_category'] ?? '').toString().isEmpty &&
                          (originalCategory.isNotEmpty ||
                              (tx['category_detailed'] ?? '')
                                  .toString()
                                  .isNotEmpty))
                        _metaChip(
                          Icons.label_outline,
                          prettyCategory(
                            detailed: tx['category_detailed']?.toString(),
                            primary: tx['category']?.toString(),
                          ),
                        ),
                      // Hide the channel chip when Plaid only knows it's
                      // "other" — that adds noise but no information.
                      // Online / in-store are the useful signal.
                      if (((tx['payment_channel'] ?? '').toString().isNotEmpty) &&
                          (tx['payment_channel'] ?? '').toString() != 'other')
                        _metaChip(
                          _channelIcon(
                              (tx['payment_channel'] ?? '').toString()),
                          _sentence((tx['payment_channel'] ?? '')
                              .toString()
                              .replaceAll('_', ' ')),
                        ),
                      if ((tx['merchant_name'] ?? '')
                              .toString()
                              .isNotEmpty &&
                          (tx['merchant_name'] ?? '').toString() !=
                              titleDescription)
                        _metaChip(Icons.storefront,
                            (tx['merchant_name'] ?? '').toString()),
                      if (pending)
                        _metaChip(Icons.hourglass_empty, 'Pending',
                            accent: Colors.orange),
                    ],
                  ),
                  if (rawDescription != titleDescription) ...[
                    const SizedBox(height: 16),
                    _sectionLabel('Raw bank text'),
                    const SizedBox(height: 4),
                    SelectableText(
                      rawDescription,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _sectionLabel('Category & notes'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: catController,
                    decoration: InputDecoration(
                      labelText: 'Category',
                      hintText: originalCategory.isNotEmpty
                          ? 'e.g. $originalCategory'
                          : null,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'Why does this transaction matter?',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 3,
                  ),
                  if (similar.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _sectionLabel('Recent at this merchant'),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Total: ${widget.currencyFormat.format(merchantTotal)} across $merchantCount transactions',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white60,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    ...similar.map((other) => _similarRow(other)),
                  ],
                  if (widget.accounts.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _sectionLabel('Move to a different account'),
                    const SizedBox(height: 6),
                    _AccountMover(
                      accounts: widget.accounts,
                      currentAccountId: tx['account_id']?.toString(),
                      onMove: (newAccountId) async {
                        Navigator.pop(context);
                        try {
                          await Future.value(widget.onUpdate?.call(
                            tx['id'],
                            accountId: newAccountId,
                          ));
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Move failed: $e')),
                          );
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (widget.onDelete != null)
                        TextButton.icon(
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete transaction?'),
                                content: const Text(
                                    'This permanently removes the transaction. To re-import from CSV/PDF you will need to upload the file again.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, true),
                                    style: TextButton.styleFrom(
                                        foregroundColor: Colors.redAccent),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm != true) return;
                            if (!mounted) return;
                            Navigator.pop(context);
                            try {
                              await widget.onDelete!(tx['id']);
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content:
                                        Text('Delete failed: $e')),
                              );
                            }
                          },
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.redAccent),
                          label: const Text('Delete',
                              style: TextStyle(color: Colors.redAccent)),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onUpdate?.call(
                            tx['id'],
                            userCategory: catController.text.trim(),
                            userNotes: notesController.text.trim(),
                          );
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
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

  Widget _sectionLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        color: Colors.white54,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }

  Widget _metaChip(IconData icon, String label, {Color? accent}) {
    final c = accent ?? Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, color: c)),
        ],
      ),
    );
  }

  String _sourceLabel(String source) {
    switch (source) {
      case 'plaid':
        return 'Synced via Plaid';
      case 'csv':
        return 'Imported (CSV)';
      case 'manual':
        return 'Manual entry';
      default:
        return source.isEmpty ? 'Unknown source' : source;
    }
  }

  /// Icon for Plaid's payment_channel ("online" / "in_store" / "other").
  IconData _channelIcon(String channel) {
    switch (channel.toLowerCase()) {
      case 'online':
        return Icons.shopping_cart_outlined;
      case 'in store':
      case 'in_store':
        return Icons.storefront_outlined;
      case 'other':
        return Icons.swap_horiz;
      default:
        return Icons.help_outline;
    }
  }

  String _sentence(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  Widget _similarRow(dynamic other) {
    final otherDate = DateTime.parse(other['date'] as String);
    final otherSourceAmount =
        ((other['amount'] as num?)?.toDouble() ?? 0.0);
    final otherSourceCurrency =
        (other['currency'] ?? widget.targetCurrency).toString();
    final otherIsExpense = otherSourceAmount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.history, size: 14, color: Colors.white38),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${DateFormat('MMM d').format(otherDate)} · ${other['account_name'] ?? ''}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${otherIsExpense ? '−' : '+'}${formatCurrencyAmount(otherSourceAmount.abs(), otherSourceCurrency)}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: otherIsExpense
                  ? Colors.white
                  : const Color(0xFF00E676),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  NumberFormat get currencyFormat => widget.currencyFormat;

  /// Title-case raw bank descriptions for cleaner display
  String _titleCase(String text) {
    // If already mostly lowercase or mixed, use as-is
    if (text != text.toUpperCase()) return text;
    // Convert ALL CAPS → Title Case
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          if (word.length <= 2) {
            return word; // Keep short tokens like "CD", "ACH"
          }
          return '${word[0]}${word.substring(1).toLowerCase()}';
        })
        .join(' ');
  }

  IconData _getCategoryIcon(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    // Plaid-style categories
    if (cat.contains('food') ||
        cat.contains('dining') ||
        desc.contains('starbucks') ||
        desc.contains('mcdonald')) {
      return Icons.restaurant;
    }
    if (cat.contains('travel') ||
        desc.contains('airline') ||
        desc.contains('united')) {
      return Icons.flight;
    }
    if (cat.contains('shopping') || desc.contains('amazon')) {
      return Icons.shopping_bag;
    }
    if (cat.contains('transfer') ||
        desc.contains('ach') ||
        desc.contains('wire')) {
      return Icons.sync_alt;
    }
    if (cat.contains('payment') ||
        desc.contains('payment') ||
        desc.contains('credit card')) {
      return Icons.payment;
    }
    if (cat.contains('entertainment') ||
        desc.contains('netflix') ||
        desc.contains('spotify')) {
      return Icons.movie;
    }
    if (cat.contains('recreation') ||
        desc.contains('climbing') ||
        desc.contains('gym')) {
      return Icons.fitness_center;
    }
    if (cat.contains('deposit') || desc.contains('deposit')) {
      return Icons.account_balance;
    }
    if (cat.contains('uber') ||
        desc.contains('uber') ||
        desc.contains('lyft')) {
      return Icons.directions_car;
    }
    if (cat.contains('personal') || cat.contains('service')) {
      return Icons.person;
    }
    return Icons.receipt;
  }

  Color _getCategoryColor(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    if (cat.contains('food') ||
        cat.contains('dining') ||
        desc.contains('starbucks') ||
        desc.contains('mcdonald')) {
      return Colors.orange;
    }
    if (cat.contains('travel') ||
        desc.contains('airline') ||
        desc.contains('united')) {
      return Colors.blue;
    }
    if (cat.contains('shopping') || desc.contains('amazon')) {
      return Colors.purple;
    }
    if (cat.contains('transfer') ||
        desc.contains('ach') ||
        desc.contains('wire')) {
      return Colors.teal;
    }
    if (cat.contains('payment') ||
        desc.contains('payment') ||
        desc.contains('credit card')) {
      return Colors.green;
    }
    if (cat.contains('entertainment') ||
        desc.contains('netflix') ||
        desc.contains('spotify')) {
      return Colors.pink;
    }
    if (cat.contains('recreation') ||
        desc.contains('climbing') ||
        desc.contains('gym')) {
      return const Color(0xFF1DE9B6);
    }
    if (cat.contains('deposit') || desc.contains('deposit')) {
      return Colors.blueAccent;
    }
    if (cat.contains('uber') ||
        desc.contains('uber') ||
        desc.contains('lyft')) {
      return Colors.indigo;
    }
    return Colors.grey;
  }
}

/// Small inline picker: shows a dropdown of accounts and reassigns the
/// transaction on selection. Filters out the current account.
class _AccountMover extends StatefulWidget {
  final List<dynamic> accounts;
  final String? currentAccountId;
  final Future<void> Function(String newAccountId) onMove;

  const _AccountMover({
    required this.accounts,
    required this.currentAccountId,
    required this.onMove,
  });

  @override
  State<_AccountMover> createState() => _AccountMoverState();
}

class _AccountMoverState extends State<_AccountMover> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final candidates = widget.accounts
        .where((a) => a['id']?.toString() != widget.currentAccountId)
        .toList();
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _selectedId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Reassign to…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: candidates.map<DropdownMenuItem<String>>((a) {
              final id = a['id'].toString();
              final name = (a['name'] ?? 'Account').toString();
              final inst = (a['institution_name'] ?? '').toString();
              return DropdownMenuItem<String>(
                value: id,
                child: Text(
                  inst.isEmpty ? name : '$inst · $name',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            }).toList(),
            onChanged: (v) => setState(() => _selectedId = v),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _selectedId == null ? null : () => widget.onMove(_selectedId!),
          child: const Text('Move'),
        ),
      ],
    );
  }
}
