import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';

/// Per-symbol dividend drill-down, opened by tapping a payer row on the
/// Portfolio tab's dividend-income card. Renders the full detail from
/// GET /dashboard/dividends/{symbol} (contract C1):
///   • header: symbol, security name, and a payment-frequency chip,
///   • a stat grid (shares, market value, rate/share, per-payment amount,
///     annual income, yield, yield-on-cost, last / est-next ex-dates),
///   • the next-12-months payment schedule with expected dollar amounts,
///   • the raw ~2y per-share payment history, and
///   • the accounts holding the symbol, badged when tax-advantaged
///     (Roth / IRA / HSA-like), since dividends there aren't taxed today.
///
/// Self-fetching (precedent: [InterestIncomeSheet]) with its own loading
/// spinner and an inline error + retry. Read-only — it mutates nothing,
/// so the card behind needs no refresh on close.
class DividendDetailSheet extends StatefulWidget {
  final ApiService apiService;
  final String symbol;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Test seam: widget tests inject a canned-payload fetcher here (the
  /// test VM can't subclass ApiService); null in production.
  @visibleForTesting
  final Future<Map<String, dynamic>> Function(String symbol)? fetchOverride;

  const DividendDetailSheet({
    super.key,
    required this.apiService,
    required this.symbol,
    required this.conversionFactor,
    required this.currencyFormat,
    this.fetchOverride,
  });

  @override
  State<DividendDetailSheet> createState() => _DividendDetailSheetState();
}

class _DividendDetailSheetState extends State<DividendDetailSheet> {
  Map<String, dynamic> _data = {};
  bool _loading = true;
  String? _error;

  /// "Payments received" starts capped at [_maxPayments] rows; the
  /// expander toggles the full list (payers-expander pattern).
  bool _showAllPayments = false;
  static const int _maxPayments = 12;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [refresh] forces a live server-side re-fetch past the dividend cache
  /// (contract C4-D). When a test's [DividendDetailSheet.fetchOverride] is
  /// set the flag is ignored — the override has no cache to bypass.
  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = widget.fetchOverride != null
          ? await widget.fetchOverride!(widget.symbol)
          : await widget.apiService
              .getDividendDetail(widget.symbol, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).pfDivDetailLoadError;
        _loading = false;
      });
    }
  }

  /// USD figure scaled into the display currency, same pattern as the
  /// dividend-income card behind this sheet.
  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  /// Per-share amounts (annual rate, history events) stay in the payer's
  /// native currency and can be sub-cent (e.g. $0.0825/share), so they
  /// keep up to four decimals instead of the display-currency format.
  String _perShare(double v, String currency) {
    final fmt = NumberFormat.currency(
      symbol: currency == 'MXN' ? r'MX$' : r'$',
      decimalDigits: v.abs() < 1 ? 4 : 2,
    );
    return fmt.format(v);
  }

  /// 12 → Monthly, 4 → Quarterly, 2 → Semi-annual, 1 → Annual; anything
  /// else falls back to the card's "N×/yr" shorthand.
  String _freqLabel(AppLocalizations l10n, int perYear) {
    switch (perYear) {
      case 12:
        return l10n.pfDivDetailFreqMonthly;
      case 4:
        return l10n.pfDivDetailFreqQuarterly;
      case 2:
        return l10n.pfDivDetailFreqSemiAnnual;
      case 1:
        return l10n.pfDivDetailFreqAnnual;
      default:
        return l10n.divPaymentsPerYear(perYear);
    }
  }

  /// Accounts where dividends compound untaxed (or tax-deferred) — worth
  /// badging so the owner knows which income is sheltered.
  bool _isTaxAdvantaged(String accountType) {
    final t = accountType.toLowerCase();
    return t.contains('roth') ||
        t.contains('ira') ||
        t.contains('hsa') ||
        t.contains('401') ||
        t.contains('403') ||
        t.contains('retirement');
  }

  String? _fmtDate(dynamic raw) {
    final s = (raw ?? '').toString();
    if (s.isEmpty) return null;
    final parsed = DateTime.tryParse(s);
    return parsed == null ? s : DateFormat.yMMMd().format(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Cap the sheet at most of the viewport; it scrolls within.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(),
            _buildHeader(l10n),
            Flexible(child: _buildBody(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      decoration: BoxDecoration(
        color: context.hairline,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    final name = (_data['name'] ?? '').toString();
    final perYear = (_data['per_year'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Icon(Icons.payments_outlined, color: context.tealAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.symbol,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!_loading && _error == null && perYear > 0) ...[
                      const SizedBox(width: 8),
                      _freqChip(_freqLabel(l10n, perYear)),
                    ],
                  ],
                ),
                if (name.isNotEmpty)
                  Text(
                    name,
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // Force-refresh (contract C4-D): bypasses the server's 12 h
          // dividend cache for a just-announced change. Disabled while a
          // load is already in flight; the existing skeleton/error states
          // are reused untouched.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.pfDivDetailRefresh,
            onPressed: _loading ? null : () => _load(refresh: true),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.actionClose,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _freqChip(String label) {
    final accent = context.tealAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: accent,
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(l10n.pfDivRetry)),
          ],
        ),
      );
    }

    final schedule = (_data['schedule'] as List?) ?? const [];
    final history = (_data['history'] as List?) ?? const [];
    final accounts = (_data['accounts'] as List?) ?? const [];
    // Real dividends received (contract C-D). Missing (older backend) or
    // empty → the section is entirely absent, never an empty shell.
    final payments = (_data['payments'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Text(
          l10n.pfDivDetailSubtitle,
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 16),
        _buildStatGrid(l10n),
        if (schedule.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildSchedule(l10n, schedule),
        ],
        if (payments.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildPayments(l10n, payments),
        ],
        const SizedBox(height: 24),
        _buildHistory(l10n, history),
        if (accounts.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildAccounts(l10n, accounts),
        ],
      ],
    );
  }

  // ---------- stat grid ----------

  Widget _buildStatGrid(AppLocalizations l10n) {
    final currency = (_data['currency'] ?? 'USD').toString();
    final quantity = (_data['quantity'] as num?)?.toDouble();
    final marketValueUsd = (_data['market_value_usd'] as num?)?.toDouble();
    final ratePerShare = (_data['rate_per_share_annual'] as num?)?.toDouble();
    final perPayment = (_data['per_payment_amount'] as num?)?.toDouble();
    final annualIncomeUsd = (_data['annual_income_usd'] as num?)?.toDouble();
    final yieldPct = (_data['yield_pct'] as num?)?.toDouble();
    final yieldOnCostPct = (_data['yield_on_cost_pct'] as num?)?.toDouble();
    final lastExDate = _fmtDate(_data['last_ex_date']);
    final nextExDate = _fmtDate(_data['est_next_ex_date']);

    final tiles = <(String, String)>[
      if (quantity != null)
        (l10n.pfDivDetailShares, NumberFormat('#,##0.####').format(quantity)),
      if (marketValueUsd != null)
        (l10n.pfDivDetailMarketValue, _money(marketValueUsd)),
      if (ratePerShare != null)
        (l10n.pfDivDetailRatePerShare, _perShare(ratePerShare, currency)),
      if (perPayment != null)
        (l10n.pfDivDetailPerPayment, _money(perPayment)),
      if (annualIncomeUsd != null)
        (l10n.pfDivDetailAnnualIncome, _money(annualIncomeUsd)),
      if (yieldPct != null)
        (l10n.pfDivDetailYield, '${yieldPct.toStringAsFixed(2)}%'),
      if (yieldOnCostPct != null)
        (l10n.pfDivDetailYieldOnCost, '${yieldOnCostPct.toStringAsFixed(2)}%'),
      (l10n.pfDivDetailLastExDate, lastExDate ?? '—'),
      (l10n.pfDivDetailNextExDate, nextExDate ?? '—'),
    ];

    return LayoutBuilder(builder: (ctx, c) {
      final perRow = c.maxWidth >= 520 ? 3 : 2;
      final tileWidth = (c.maxWidth - 12 * (perRow - 1)) / perRow;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final (label, value) in tiles)
            SizedBox(width: tileWidth, child: _statTile(label, value)),
        ],
      );
    });
  }

  Widget _statTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ---------- next-12-months schedule ----------

  Widget _buildSchedule(AppLocalizations l10n, List<dynamic> schedule) {
    final rows = schedule.whereType<Map>().map((m) {
      final r = m.cast<String, dynamic>();
      return (
        date: _fmtDate(r['est_date']) ?? '—',
        amountUsd: (r['est_amount_usd'] as num?)?.toDouble(),
      );
    }).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.pfDivDetailSchedule),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1,
                      color: context.hairline.withValues(alpha: 0.5)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.event_outlined,
                          size: 15, color: context.textSubtle),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          rows[i].date,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Text(
                        rows[i].amountUsd == null
                            ? '—'
                            : _money(rows[i].amountUsd!),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.positive,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ---------- payments actually received (contract C-D) ----------

  /// The dollars that actually landed: positive dividend-tagged
  /// transactions matched to this symbol's accounts, newest first from
  /// the API. Date + account name (muted, truncating) + USD amount
  /// right-aligned; capped at [_maxPayments] behind a "Show all (N)"
  /// expander like the card's payer list.
  Widget _buildPayments(AppLocalizations l10n, List<dynamic> payments) {
    final rows = payments.whereType<Map>().map((m) {
      final r = m.cast<String, dynamic>();
      return (
        date: _fmtDate(r['date']) ?? '—',
        account: (r['account_name'] ?? '').toString(),
        amountUsd: (r['amount_usd'] as num?)?.toDouble(),
      );
    }).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    final visible = _showAllPayments ? rows : rows.take(_maxPayments).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.insDivPaymentsSection),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1,
                      color: context.hairline.withValues(alpha: 0.5)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Text(
                        visible[i].date,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          visible[i].account,
                          style:
                              TextStyle(fontSize: 12, color: context.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        visible[i].amountUsd == null
                            ? '—'
                            : '+${_money(visible[i].amountUsd!)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.positive,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (rows.length > _maxPayments)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () =>
                  setState(() => _showAllPayments = !_showAllPayments),
              child: Text(_showAllPayments
                  ? l10n.insDivShowFewerPayments
                  : l10n.insDivShowAllPayments(rows.length)),
            ),
          ),
      ],
    );
  }

  // ---------- per-share payment history ----------

  Widget _buildHistory(AppLocalizations l10n, List<dynamic> history) {
    final currency = (_data['currency'] ?? 'USD').toString();
    // API order is ascending by ex-date; most-recent-first reads better in
    // a top-anchored sheet.
    final rows = history.whereType<Map>().map((m) {
      final r = m.cast<String, dynamic>();
      return (
        date: _fmtDate(r['ex_date']) ?? '—',
        amount: (r['amount_per_share'] as num?)?.toDouble(),
      );
    }).toList();
    final ordered = rows.reversed.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.pfDivDetailHistory),
        const SizedBox(height: 8),
        if (ordered.isEmpty)
          // Graceful body for user-held but Yahoo-unresolvable symbols
          // (401k trusts, CUR:USD) — an empty history is not an error.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(Icons.history_toggle_off,
                    size: 16, color: context.textSubtle),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.pfDivDetailNoHistory,
                    style: TextStyle(fontSize: 13, color: context.textMuted),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: context.tileSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.hairline),
            ),
            child: Column(
              children: [
                for (var i = 0; i < ordered.length; i++) ...[
                  if (i > 0)
                    Divider(
                        height: 1,
                        color: context.hairline.withValues(alpha: 0.5)),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            ordered[i].date,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ),
                        Text(
                          ordered[i].amount == null
                              ? '—'
                              : '${_perShare(ordered[i].amount!, currency)} ${l10n.pfDivDetailPerShare}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: context.textMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  // ---------- accounts holding the symbol ----------

  Widget _buildAccounts(AppLocalizations l10n, List<dynamic> accounts) {
    final rows =
        accounts.whereType<Map>().map((m) => m.cast<String, dynamic>());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.pfDivDetailAccounts),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            children: [
              for (final r in rows) _accountRow(l10n, r),
            ],
          ),
        ),
      ],
    );
  }

  Widget _accountRow(AppLocalizations l10n, Map<String, dynamic> r) {
    final name = (r['account_name'] ?? '').toString();
    final type = (r['account_type'] ?? '').toString();
    final qty = (r['quantity'] as num?)?.toDouble() ?? 0.0;
    final taxAdvantaged = _isTaxAdvantaged(type);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isNotEmpty ? name : '—',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (type.isNotEmpty)
                  Text(
                    type,
                    style: TextStyle(fontSize: 11, color: context.textSubtle),
                  ),
              ],
            ),
          ),
          if (taxAdvantaged) ...[
            _taxAdvantagedBadge(l10n),
            const SizedBox(width: 10),
          ],
          Text(
            l10n.pfSharesSuffix(NumberFormat('#,##0.####').format(qty)),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _taxAdvantagedBadge(AppLocalizations l10n) {
    final color = context.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        l10n.pfDivDetailTaxAdvantaged,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: context.textSubtle,
      ),
    );
  }
}
