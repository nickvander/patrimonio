import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/preferences.dart';
import '../utils/currency.dart';

class PortfolioCard extends StatefulWidget {
  final Map<String, dynamic> portfolioData;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  /// Optional category filter pushed in from the AllocationHeatmap above.
  /// When non-null, only holdings whose category (or sub-category) match
  /// pass through into the table.
  final String? categoryFilter;
  /// Tap handler for clearing the active category filter via a chip on
  /// top of the holdings table.
  final VoidCallback? onClearCategoryFilter;

  const PortfolioCard({
    super.key,
    required this.portfolioData,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.categoryFilter,
    this.onClearCategoryFilter,
  });

  @override
  State<PortfolioCard> createState() => _PortfolioCardState();
}

class _PortfolioCardState extends State<PortfolioCard> {
  int? _sortColumnIndex = 3; // Default sort by Value
  bool _isAscending = false;
  late List<dynamic> _allHoldings;
  late List<dynamic> _holdings;
  int _touchedIndex = -1;
  String _searchQuery = '';
  bool _groupByAccount = false;

  @override
  void initState() {
    super.initState();
    _groupByAccount = Preferences.getGroupByAccount();
    _allHoldings = List.from(widget.portfolioData['holdings'] ?? []);
    _holdings = List.from(_allHoldings);
    _sort(3, false);
  }

  @override
  void didUpdateWidget(PortfolioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.portfolioData != oldWidget.portfolioData ||
        widget.conversionFactor != oldWidget.conversionFactor ||
        widget.categoryFilter != oldWidget.categoryFilter) {
      _allHoldings = List.from(widget.portfolioData['holdings'] ?? []);
      _applySearch();
      _sort(_sortColumnIndex ?? 3, _isAscending);
    }
  }

  void _applySearch() {
    final q = _searchQuery.toLowerCase().trim();
    final catFilter = widget.categoryFilter?.toLowerCase().trim() ?? '';
    bool matchesCat(Map h) {
      if (catFilter.isEmpty) return true;
      // The heatmap groups by both 'category' and 'sub_category' so we
      // accept a match on either to keep the filter intuitive.
      final cat = (h['category'] ?? '').toString().toLowerCase();
      final sub = (h['sub_category'] ?? '').toString().toLowerCase();
      return cat == catFilter || sub == catFilter;
    }

    final base = _allHoldings.where((h) => matchesCat(h as Map)).toList();
    if (q.isEmpty) {
      _holdings = base;
    } else {
      _holdings = base.where((h) {
        final sym = (h['symbol'] ?? '').toString().toLowerCase();
        final name = (h['name'] ?? '').toString().toLowerCase();
        final inst = (h['institution_name'] ?? '').toString().toLowerCase();
        final acct = (h['account_name'] ?? '').toString().toLowerCase();
        return sym.contains(q) ||
            name.contains(q) ||
            inst.contains(q) ||
            acct.contains(q);
      }).toList();
    }
  }

  void _sort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _isAscending = ascending;

      _holdings.sort((a, b) {
        dynamic valA;
        dynamic valB;

        switch (columnIndex) {
          case 0:
            valA = a['symbol']?.toString() ?? '';
            valB = b['symbol']?.toString() ?? '';
            break;
          case 1:
            valA = (a['quantity'] as num?)?.toDouble() ?? 0.0;
            valB = (b['quantity'] as num?)?.toDouble() ?? 0.0;
            break;
          case 2:
            valA = (a['price'] as num?)?.toDouble() ?? 0.0;
            valB = (b['price'] as num?)?.toDouble() ?? 0.0;
            break;
          case 3:
            valA = (a['value'] as num?)?.toDouble() ?? 0.0;
            valB = (b['value'] as num?)?.toDouble() ?? 0.0;
            break;
          case 4:
            valA = (a['cost_basis'] as num?)?.toDouble() ?? 0.0;
            valB = (b['cost_basis'] as num?)?.toDouble() ?? 0.0;
            break;
          case 5:
            valA = (a['gain_loss'] as num?)?.toDouble() ?? 0.0;
            valB = (b['gain_loss'] as num?)?.toDouble() ?? 0.0;
            break;
          case 6:
            valA = (a['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
            valB = (b['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
            break;
          default:
            valA = 0;
            valB = 0;
        }

        if (!ascending) {
          final temp = valA;
          valA = valB;
          valB = temp;
        }

        return Comparable.compare(valA as Comparable, valB as Comparable);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalValue =
        ((widget.portfolioData['total_value'] as num?)?.toDouble() ?? 0.0) *
        widget.conversionFactor;
    final totalGainLoss =
        ((widget.portfolioData['total_gain_loss'] as num?)?.toDouble() ?? 0.0) *
        widget.conversionFactor;
    final totalGainLossPct =
        (widget.portfolioData['total_gain_loss_pct'] as num?)?.toDouble() ??
        0.0;

    final isPositive = totalGainLoss >= 0;

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(builder: (context, c) {
              // Below ~680px the hero (Expanded summary + Expanded chart)
              // squeezes both panels. Stack instead, and shrink the big
              // total-value number so a long "USD 1,234,567.89" still
              // fits a phone-width card without wrapping or ellipsis.
              final isNarrow = c.maxWidth < 680;
              final heroFontSize = c.maxWidth < 400
                  ? 30.0
                  : c.maxWidth < 520
                      ? 36.0
                      : 42.0;
              final summary = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Investment portfolio',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Total value',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.currencyFormat.format(totalValue),
                      style: TextStyle(
                        fontSize: heroFontSize,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.0,
                        height: 1.1,
                        color: Colors.white,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: (isPositive
                              ? const Color(0xFF00E676)
                              : Colors.redAccent)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isPositive
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          color: isPositive
                              ? const Color(0xFF00E676)
                              : Colors.redAccent,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${isPositive ? '+' : ''}${widget.currencyFormat.format(totalGainLoss.abs())} (${totalGainLossPct.toStringAsFixed(2)}%)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: isPositive
                                  ? const Color(0xFF00E676)
                                  : Colors.redAccent,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              final chart = SizedBox(
                height: isNarrow ? 200 : 220,
                child: _buildAllocationChart(),
              );
              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    summary,
                    const SizedBox(height: 24),
                    chart,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: summary),
                  Expanded(child: chart),
                ],
              );
            }),
            const SizedBox(height: 24),
            _buildKpiStrip(),
            const SizedBox(height: 20),
            Theme(
              data: Theme.of(context).copyWith(
                cardTheme: CardThemeData(
                  color: const Color(0xFF1A1A24),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                dividerColor: Colors.white12,
              ),
              child: _groupByAccount
                  ? _buildGroupedHoldings()
                  : _buildHoldingsTable(),
            ),
          ],
        ),
      ),
    );
  }

  /// Four-tile compact stat strip above the holdings table.
  /// Surfaces at-a-glance facts about the portfolio so the user doesn't
  /// have to mentally scan the whole table.
  Widget _buildKpiStrip() {
    if (_allHoldings.isEmpty) return const SizedBox.shrink();

    final cf = widget.conversionFactor;
    Map<String, dynamic>? top;
    Map<String, dynamic>? gainer;
    Map<String, dynamic>? loser;

    for (final h in _allHoldings) {
      final v = ((h['value'] as num?)?.toDouble() ?? 0.0);
      if (top == null || v > ((top['value'] as num).toDouble())) top = h;
      final pct = (h['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
      if (gainer == null ||
          pct > ((gainer['gain_loss_pct'] as num?)?.toDouble() ?? 0)) {
        gainer = h;
      }
      if (loser == null ||
          pct < ((loser['gain_loss_pct'] as num?)?.toDouble() ?? 0)) {
        loser = h;
      }
    }

    String displayTicker(Map<String, dynamic> h) {
      final sym = (h['symbol'] ?? '').toString();
      final name = (h['name'] ?? '').toString();
      // Hide Plaid security_id hashes — fall back to security name.
      if (sym.length > 8 ||
          (sym != sym.toUpperCase() && sym.length > 4)) {
        return name.isNotEmpty ? name : '—';
      }
      return sym.isEmpty ? (name.isNotEmpty ? name : '?') : sym;
    }

    final tiles = <_KpiTile>[
      _KpiTile(
        label: 'Holdings',
        value: '${_allHoldings.length}',
        sub:
            '${_allHoldings.map((h) => (h['account_name'] ?? '').toString()).toSet().where((s) => s.isNotEmpty).length} accounts',
      ),
      if (top != null)
        _KpiTile(
          label: 'Top position',
          value: displayTicker(top),
          sub: widget.currencyFormat
              .format(((top['value'] as num).toDouble()) * cf),
          accent: const Color(0xFF1DE9B6),
        ),
      if (gainer != null &&
          ((gainer['gain_loss_pct'] as num?)?.toDouble() ?? 0) > 0)
        _KpiTile(
          label: 'Biggest gainer',
          value: displayTicker(gainer),
          sub:
              '+${((gainer['gain_loss_pct'] as num).toDouble()).toStringAsFixed(2)}%',
          accent: const Color(0xFF00E676),
        ),
      if (loser != null &&
          ((loser['gain_loss_pct'] as num?)?.toDouble() ?? 0) < 0)
        _KpiTile(
          label: 'Biggest loser',
          value: displayTicker(loser),
          sub:
              '${((loser['gain_loss_pct'] as num).toDouble()).toStringAsFixed(2)}%',
          accent: Colors.redAccent,
        ),
    ];

    return LayoutBuilder(builder: (ctx, c) {
      // 4-up at wide, 2-up at medium, stacked at narrow.
      final width = c.maxWidth;
      final perRow = width >= 880
          ? 4
          : width >= 520
              ? 2
              : 1;
      final tileWidth = (width - 12 * (perRow - 1)) / perRow;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: tiles
            .map((t) => SizedBox(width: tileWidth, child: t))
            .toList(),
      );
    });
  }

  /// Collapses the holdings list into one section per account, with a
  /// per-account subtotal in the header. Sections are sorted by
  /// account total (descending) so the largest account leads.
  Widget _buildGroupedHoldings() {
    if (_holdings.isEmpty) {
      return _buildHoldingsTable(); // reuse empty state
    }
    final byAccount = <String, List<dynamic>>{};
    for (final h in _holdings) {
      final acct = (h['account_name'] ?? 'Unknown').toString();
      byAccount.putIfAbsent(acct, () => []).add(h);
    }
    final entries = byAccount.entries.toList()
      ..sort((a, b) {
        final sa = a.value.fold<double>(
            0,
            (s, h) =>
                s + ((h['value'] as num?)?.toDouble() ?? 0.0));
        final sb = b.value.fold<double>(
            0,
            (s, h) =>
                s + ((h['value'] as num?)?.toDouble() ?? 0.0));
        return sb.compareTo(sa);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchAndToolbar(),
        const SizedBox(height: 12),
        ...entries.map((entry) {
          final acct = entry.key;
          final list = List.from(entry.value);
          list.sort((a, b) {
            final va = ((a['value'] as num?)?.toDouble() ?? 0.0);
            final vb = ((b['value'] as num?)?.toDouble() ?? 0.0);
            return vb.compareTo(va);
          });
          final subtotal = list.fold<double>(
              0,
              (s, h) =>
                  s + ((h['value'] as num?)?.toDouble() ?? 0.0)) *
              widget.conversionFactor;
          final inst =
              (list.first['institution_name'] ?? '').toString();
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.02),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              acct,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (inst.isNotEmpty)
                              Text(
                                '$inst · ${list.length} ${list.length == 1 ? "position" : "positions"}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white54,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        widget.currencyFormat.format(subtotal),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                ...list.map((h) => _buildCompactHoldingRow(h)),
              ],
            ),
          );
        }),
      ],
    );
  }

  /// Compact row used by the grouped-by-account view. Single line, no
  /// table chrome — just ticker, qty, value, return.
  Widget _buildCompactHoldingRow(dynamic h) {
    final cf = widget.conversionFactor;
    final qty = (h['quantity'] as num?)?.toDouble() ?? 0.0;
    final value = ((h['value'] as num?)?.toDouble() ?? 0.0) * cf;
    final pct = (h['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
    final isGain = pct >= 0;
    final rawSym = (h['symbol'] ?? '').toString();
    final rawName = (h['name'] ?? '').toString();
    final opaque = rawSym.length > 8 ||
        (rawSym != rawSym.toUpperCase() && rawSym.length > 4);
    final displaySymbol = opaque
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSym.isEmpty ? (rawName.isNotEmpty ? rawName : '?') : rawSym);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Tooltip(
              message: rawName.isNotEmpty ? rawName : displaySymbol,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                displaySymbol,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${_formatQuantity(qty)} sh',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white60,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              widget.currencyFormat.format(value),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: Text(
              '${isGain ? '+' : ''}${pct.toStringAsFixed(2)}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color:
                    isGain ? const Color(0xFF00E676) : Colors.redAccent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Search field + group/flat toggle. Used by both renderers.
  Widget _buildSearchAndToolbar() {
    final totalHoldings = _allHoldings.length;
    final shownHoldings = _holdings.length;
    final accountCount = _allHoldings
        .map((h) => (h['account_name'] ?? '').toString())
        .toSet()
        .where((s) => s.isNotEmpty)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.categoryFilter != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(Icons.filter_alt, size: 16),
                  label: Text(
                      'Category: ${widget.categoryFilter}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onDeleted: widget.onClearCategoryFilter,
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                onChanged: (v) => setState(() {
                  _searchQuery = v;
                  _applySearch();
                  _sort(_sortColumnIndex ?? 3, _isAscending);
                }),
                decoration: InputDecoration(
                  hintText:
                      'Search ticker, name, account, or institution…',
                  hintStyle: const TextStyle(
                      color: Colors.white54, fontSize: 13),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 18,
                    color: Colors.white54,
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 0, horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _searchQuery.isEmpty
                ? '$totalHoldings ${totalHoldings == 1 ? "holding" : "holdings"} · $accountCount ${accountCount == 1 ? "account" : "accounts"}'
                : '$shownHoldings of $totalHoldings',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(width: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.list_alt, size: 14),
                label: Text('Flat'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.account_tree_outlined, size: 14),
                label: Text('By account'),
              ),
            ],
            selected: {_groupByAccount},
            onSelectionChanged: (s) {
              setState(() => _groupByAccount = s.first);
              Preferences.setGroupByAccount(s.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 12)),
            ),
          ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHoldingsTable() {
    if (_holdings.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchAndToolbar(),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.all(48.0),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.show_chart, size: 56, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  const Text(
                    'No holdings yet',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Once you link a brokerage with Plaid (or import a CSV) your\npositions will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        // Use the larger of (natural width, available) so on wide screens
        // we don't leave a giant gap on the right.
        final tableWidth = available > _kTableNaturalWidth
            ? available
            : _kTableNaturalWidth;

        // Cap the scrollable body so the inner viewport fits the page.
        // Below the cap, we hug the data so short portfolios don't show
        // a giant whitespace pad under the rows.
        final bodyHeight = _holdings.length * _kRowHeight > _kMaxBodyHeight
            ? _kMaxBodyHeight
            : _holdings.length * _kRowHeight;

        final table = SizedBox(
          width: tableWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTableHeader(),
              const Divider(color: Colors.white12, height: 1, thickness: 1),
              SizedBox(
                height: bodyHeight,
                child: Scrollbar(
                  thumbVisibility: true,
                  child: ListView.builder(
                    itemCount: _holdings.length,
                    itemExtent: _kRowHeight,
                    itemBuilder: (ctx, i) => _HoldingRowTile(
                      holding: _holdings[i],
                      format: widget.currencyFormat,
                      targetCurrency: widget.targetCurrency,
                      usdMxnRate: widget.usdMxnRate,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        // Horizontal scroll only when the viewport is narrower than the
        // table's natural width. On wide screens the table fills the
        // container and the asset column gets the extra space.
        final body = available < _kTableNaturalWidth
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: table,
              )
            : table;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchAndToolbar(),
            const SizedBox(height: 12),
            body,
          ],
        );
      },
    );
  }

  /// Click-to-sort header row. First click on a new column sorts ascending,
  /// subsequent clicks toggle direction. Matches PaginatedDataTable behavior.
  Widget _buildTableHeader() {
    Widget label(String text, int colIndex, {bool numeric = true}) {
      final active = _sortColumnIndex == colIndex;
      return InkWell(
        onTap: () {
          if (_sortColumnIndex == colIndex) {
            _sort(colIndex, !_isAscending);
          } else {
            _sort(colIndex, true);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Align(
            alignment:
                numeric ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : Colors.white60,
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 12,
                    color: const Color(0xFF00E676),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return _tableRow(
      asset: label('Asset', 0, numeric: false),
      shares: label('Shares', 1),
      price: label('Price', 2),
      value: label('Value', 3),
      costBasis: label('Cost basis', 4),
      gain: label('Gain', 5),
      returnPct: label('Return', 6),
    );
  }

  Widget _buildAllocationChart() {
    if (_holdings.isEmpty) return const SizedBox.shrink();

    final colors = [
      const Color(0xFF1DE9B6), // Neon Teal
      const Color(0xFF7C4DFF), // Deep Violet
      const Color(0xFFFF4081), // Pink Accent
      const Color(0xFFFFD740), // Bright Gold
      const Color(0xFF2979FF), // Vivid Blue
    ];

    final sortedHoldings = List.from(_holdings)
      ..sort(
        (a, b) =>
            ((b['value'] ?? 0) as num).compareTo((a['value'] ?? 0) as num),
      );

    List<PieChartSectionData> sections = [];
    List<Widget> legendItems = [];
    double otherValue = 0.0;

    for (int i = 0; i < sortedHoldings.length; i++) {
      final h = sortedHoldings[i];
      final value = (h['value'] ?? 0.0).toDouble();

      if (value <= 0) continue;
      final percentage = value / widget.portfolioData['total_value'];
      final isTouched = i == _touchedIndex;
      final radius = isTouched ? 60.0 : 50.0;

      if (i < 4) {
        final color = colors[i % colors.length];
        sections.add(
          PieChartSectionData(
            color: color,
            value: value,
            title: isTouched ? '${(percentage * 100).toStringAsFixed(1)}%' : '',
            radius: radius,
            titleStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              shadows: [Shadow(color: Colors.black, blurRadius: 6)],
            ),
            badgeWidget: isTouched
                ? Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A24),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(Icons.show_chart, color: color, size: 14),
                  )
                : null,
            badgePositionPercentageOffset: 1.15,
          ),
        );
        legendItems.add(
          _buildLegendItem(
            color,
            h['name'] ?? h['symbol'] ?? '?',
            percentage,
            isTouched,
          ),
        );
      } else {
        otherValue += value;
      }
    }

    if (otherValue > 0) {
      final percentage = otherValue / widget.portfolioData['total_value'];
      final isTouched = _touchedIndex == 4;
      final radius = isTouched ? 60.0 : 50.0;
      sections.add(
        PieChartSectionData(
          color: Colors.grey.shade700,
          value: otherValue,
          title: isTouched ? '${(percentage * 100).toStringAsFixed(1)}%' : '',
          radius: radius,
          titleStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      );
      legendItems.add(
        _buildLegendItem(Colors.grey.shade700, 'Other', percentage, isTouched),
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: PieChart(
            PieChartData(
              pieTouchData: PieTouchData(
                touchCallback: (FlTouchEvent event, pieTouchResponse) {
                  setState(() {
                    if (!event.isInterestedForInteractions ||
                        pieTouchResponse == null ||
                        pieTouchResponse.touchedSection == null) {
                      _touchedIndex = -1;
                      return;
                    }
                    _touchedIndex =
                        pieTouchResponse.touchedSection!.touchedSectionIndex;
                  });
                },
              ),
              sections: sections,
              centerSpaceRadius: 50,
              sectionsSpace: 4,
            ),
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          flex: 2,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: legendItems,
          ),
        ),
      ],
    );
  }

  Widget _buildLegendItem(
    Color color,
    String label,
    double percentage,
    bool isTouched,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      decoration: BoxDecoration(
        color: isTouched ? color.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: isTouched
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ]
                  : [],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isTouched ? FontWeight.bold : FontWeight.w600,
                color: isTouched ? color : Colors.white,
              ),
            ),
          ),
          Text(
            '${(percentage * 100).toStringAsFixed(1)}%',
            style: TextStyle(
              color: isTouched ? color : Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Trim trailing zeros and pick a sensible precision based on the
/// magnitude of the share count: integers stay integer, normal lots
/// show 2 decimals, fractional crypto-style holdings keep 4.
String _formatQuantity(double q) {
  if (q == q.roundToDouble() && q.abs() < 1e9) {
    return q.toInt().toString();
  }
  if (q.abs() >= 1) {
    return q
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
  return q
      .toStringAsFixed(4)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}

// Layout constants for the virtualized holdings table. Header and body
// share the same column widths so they line up visually as the user
// scrolls. The natural width sits around 1080; below that the table
// scrolls horizontally instead of squeezing columns.
const double _kRowHeight = 60.0;
const double _kMaxBodyHeight = 600.0;
const double _kTableNaturalWidth = 1080.0;
const double _kHMargin = 20.0;
const double _kColShares = 100.0;
const double _kColPrice = 124.0;
const double _kColValue = 152.0;
const double _kColCost = 132.0;
const double _kColGain = 140.0;
const double _kColReturn = 108.0;

/// Shared row layout used by the header and every body row. Asset takes
/// the remaining space; numeric columns are fixed width so values line
/// up vertically.
Widget _tableRow({
  required Widget asset,
  required Widget shares,
  required Widget price,
  required Widget value,
  required Widget costBasis,
  required Widget gain,
  required Widget returnPct,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: _kHMargin),
    child: Row(
      children: [
        Expanded(child: asset),
        SizedBox(width: _kColShares, child: shares),
        SizedBox(width: _kColPrice, child: price),
        SizedBox(width: _kColValue, child: value),
        SizedBox(width: _kColCost, child: costBasis),
        SizedBox(width: _kColGain, child: gain),
        SizedBox(width: _kColReturn, child: returnPct),
      ],
    ),
  );
}

/// A single holding row used inside the virtualized ListView. Stateful
/// so that hover-over highlight doesn't have to rebuild the whole table.
class _HoldingRowTile extends StatefulWidget {
  final dynamic holding;
  final NumberFormat format;
  final String targetCurrency;
  final double usdMxnRate;

  const _HoldingRowTile({
    required this.holding,
    required this.format,
    required this.targetCurrency,
    required this.usdMxnRate,
  });

  @override
  State<_HoldingRowTile> createState() => _HoldingRowTileState();
}

class _HoldingRowTileState extends State<_HoldingRowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.holding;
    final gain = (h['gain_loss'] as num?)?.toDouble() ?? 0.0;
    final gainPct = (h['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
    final quantity = (h['quantity'] as num?)?.toDouble() ?? 0.0;
    final sourceCurrency = (h['currency'] ?? widget.targetCurrency).toString();
    final sourcePrice = (h['price'] as num?)?.toDouble() ?? 0.0;
    final sourceValue = (h['value'] as num?)?.toDouble() ?? 0.0;
    final costBasisSource = (h['cost_basis'] as num?)?.toDouble() ?? 0.0;
    final price = convertCurrency(
      sourcePrice,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final value = convertCurrency(
      sourceValue,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final costBasis = convertCurrency(
      costBasisSource,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final gainConverted = convertCurrency(
      gain,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final isGain = gain >= 0;

    final rawSymbol = (h['symbol'] ?? '').toString();
    final rawName = (h['name'] ?? '').toString();
    final acctName = (h['account_name'] ?? '').toString();
    final instName = (h['institution_name'] ?? '').toString();
    // Plaid emits opaque security_ids (e.g. "3mg4qV4JZycPL4qeZgB...") for
    // un-tickered Vanguard mutual funds. Real tickers are short and upper-
    // case; security_ids are long and mixed-case.
    final isOpaqueSecurityId = rawSymbol.length > 8 ||
        (rawSymbol != rawSymbol.toUpperCase() && rawSymbol.length > 4);
    final displaySymbol = isOpaqueSecurityId
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSymbol.isEmpty
            ? (rawName.isNotEmpty ? rawName : '?')
            : rawSymbol);
    // Secondary line: security name (when it isn't already the display
    // symbol), institution, and account — joined with bullets. Surfacing
    // `account_name` lets users with positions split across several
    // brokerages tell them apart at a glance.
    final secondaryParts = <String>[
      if (!isOpaqueSecurityId && rawName.isNotEmpty) rawName,
      if (instName.isNotEmpty) instName,
      if (acctName.isNotEmpty && acctName != instName) acctName,
    ];
    final secondaryLabel = secondaryParts.join(' · ');
    final avatarChar = displaySymbol.isEmpty
        ? '?'
        : displaySymbol.substring(0, 1).toUpperCase();

    final asset = Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFF2A2A35),
            radius: 16,
            child: Text(
              avatarChar,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  displaySymbol,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  secondaryLabel,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final shares = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          _formatQuantity(quantity),
          style: const TextStyle(
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          'sh',
          style: TextStyle(fontSize: 11, color: Colors.white38),
        ),
      ],
    );

    final priceCell = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.format.format(price),
          style: const TextStyle(
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (sourceCurrency != widget.targetCurrency)
          Text(
            formatCurrencyAmount(sourcePrice, sourceCurrency),
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white38,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );

    final valueCell = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.format.format(value),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (sourceCurrency != widget.targetCurrency)
          Text(
            formatCurrencyAmount(sourceValue, sourceCurrency),
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white38,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );

    final costBasisCell = Align(
      alignment: Alignment.centerRight,
      child: Text(
        costBasisSource == 0 ? '—' : widget.format.format(costBasis),
        style: TextStyle(
          fontSize: 14,
          color: costBasisSource == 0 ? Colors.white38 : Colors.white70,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    final gainCell = Align(
      alignment: Alignment.centerRight,
      child: gain == 0
          ? const Text(
              '—',
              style: TextStyle(fontSize: 14, color: Colors.white38),
            )
          : Text(
              '${isGain ? '+' : ''}${widget.format.format(gainConverted)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color:
                    isGain ? const Color(0xFF00E676) : Colors.redAccent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
    );

    final returnCell = Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: (isGain ? const Color(0xFF00E676) : Colors.redAccent)
              .withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${isGain ? '+' : ''}${gainPct.toStringAsFixed(2)}%',
          style: TextStyle(
            color: isGain ? const Color(0xFF00E676) : Colors.redAccent,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color:
            _hover ? Colors.white.withValues(alpha: 0.05) : Colors.transparent,
        child: _tableRow(
          asset: asset,
          shares: shares,
          price: priceCell,
          value: valueCell,
          costBasis: costBasisCell,
          gain: gainCell,
          returnPct: returnCell,
        ),
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? accent;

  const _KpiTile({
    required this.label,
    required this.value,
    this.sub,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = accent ?? Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Colors.white60,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(
              sub!,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.55),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
