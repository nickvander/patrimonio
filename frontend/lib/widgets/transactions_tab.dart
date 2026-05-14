import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/currency.dart';

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
  });

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  String _searchQuery = '';

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
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No transactions found.',
              style: TextStyle(color: Colors.grey, fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              'Link an institution or sync to see recent activity.',
              style: TextStyle(color: Colors.grey),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Recent transactions',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                SizedBox(
                  width: 280,
                  height: 40,
                  child: TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    decoration: InputDecoration(
                      hintText: 'Search transactions…',
                      hintStyle: const TextStyle(
                        color: Colors.white30,
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 18,
                        color: Colors.white30,
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 0,
                        horizontal: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Showing ${filtered.length} of ${widget.transactions.length}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 32, color: Colors.white10),
              itemBuilder: (context, index) {
                return _buildTransactionRow(filtered[index]);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// One row in the transactions list. Layout: 48px category icon, then a
  /// description column (title + small meta), then a right-aligned amount
  /// block. Real amount is shown in the transaction's native currency;
  /// an estimated conversion to the reporting currency is appended below
  /// only when the two currencies differ.
  Widget _buildTransactionRow(dynamic tx) {
    final date = DateTime.parse(tx['date'] as String);
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
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _getCategoryIcon(category, tx['description']),
                color: color,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titleCase(tx['description'] ?? 'Unknown Transaction'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _metaLine(tx, date, notes),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Fixed-width amount column so eyes can scan straight down.
            // Real amount = native currency (top, bold). Estimated
            // conversion appears below only when there's a real FX leap.
            SizedBox(
              width: 132,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: isExpense
                          ? Colors.white
                          : const Color(0xFF00E676),
                    ),
                  ),
                  if (needsConversion)
                    Text(
                      '≈ ${widget.currencyFormat.format(converted.abs())}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                        fontStyle: FontStyle.italic,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  if (tx['pending'] == true)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
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

  String _metaLine(dynamic tx, DateTime date, String notes) {
    final account = (tx['account_name'] ?? '').toString();
    final dateStr = DateFormat('MMM d').format(date);
    final parts = <String>[
      if (account.isNotEmpty) account,
      dateStr,
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

    // Find the 3 most recent transactions with the same raw description
    // (excluding the current one). Lets users see merchant-level context
    // without leaving the modal.
    final similar = widget.transactions.where((other) {
      if (other['id'] == tx['id']) return false;
      return (other['description'] ?? '').toString().trim().toLowerCase() ==
          rawDescription.trim().toLowerCase();
    }).take(3).toList();

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
                      if (originalCategory.isNotEmpty &&
                          originalCategory !=
                              (tx['user_category'] ?? '').toString())
                        _metaChip(Icons.label_outline,
                            'Auto: $originalCategory'),
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
