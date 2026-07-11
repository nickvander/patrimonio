import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// Interest-income drill-down (cash basis) reachable from the Lending
/// tab. Renders the full report from GET /loans/interest-income:
///   • a per-month bar of interest received,
///   • a per-loan table (interest / principal / payment count),
///   • per-currency totals shown SIDE-BY-SIDE per currency (MXN and USD
///     are NEVER summed across the FX boundary), and
///   • a §7872 callout listing any below-market (0%-rate) loans.
///
/// A year selector re-fetches with ?year=. Read-only — it mutates
/// nothing, so the host tab needs no refresh on close.
class InterestIncomeSheet extends StatefulWidget {
  final ApiService apiService;

  const InterestIncomeSheet({super.key, required this.apiService});

  @override
  State<InterestIncomeSheet> createState() => _InterestIncomeSheetState();
}

class _InterestIncomeSheetState extends State<InterestIncomeSheet> {
  // null = all-time. Otherwise a calendar year (cash basis, by paid_date).
  int? _year = DateTime.now().year;
  Map<String, dynamic> _data = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.apiService.getInterestIncome(year: _year);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).lendingInterestIncomeLoadError;
        _loading = false;
      });
    }
  }

  /// Native-currency money, mirroring LendingTab._money: no sub-cent
  /// residue, MX$ vs $ symbol by currency.
  String _money(num v, String currency) {
    final fmt = NumberFormat.currency(
      symbol: currency == 'MXN' ? r'MX$' : r'$',
      decimalDigits: 2,
    );
    return fmt.format(v.abs() < 0.005 ? 0 : v);
  }

  /// Display variant of [_money] for headline stats and per-loan rows:
  /// cents drop at the whole-money threshold. The monthly breakdown table
  /// keeps the exact [_money] — its rows sum to reconcilable totals.
  String _moneyDisplay(num v, String currency) {
    final fmt = NumberFormat.currency(
      symbol: currency == 'MXN' ? r'MX$' : r'$',
      decimalDigits: 2,
    );
    return fmt.displayMoney(v.abs() < 0.005 ? 0 : v);
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Icon(Icons.insights_outlined, color: context.tealAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.lendingInterestIncomeTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
          ),
          _yearSelector(l10n),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.actionClose,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  /// Year filter. The current and a handful of prior years, plus an
  /// "all time" option (null), re-fetching on change.
  Widget _yearSelector(AppLocalizations l10n) {
    final thisYear = DateTime.now().year;
    final years = [for (var y = thisYear; y >= thisYear - 6; y--) y];
    return DropdownButton<int?>(
      value: _year,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(10),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.textPrimary,
      ),
      items: [
        DropdownMenuItem<int?>(
          value: null,
          child: Text(l10n.lendingInterestIncomeAllTime),
        ),
        for (final y in years)
          DropdownMenuItem<int?>(value: y, child: Text('$y')),
      ],
      onChanged: (v) {
        if (v == _year) return;
        setState(() => _year = v);
        _load();
      },
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
            FilledButton(
                onPressed: _load, child: Text(l10n.lendingInterestIncomeRetry)),
          ],
        ),
      );
    }

    final byMonth = (_data['by_month'] as List?) ?? const [];
    final byLoan = (_data['by_loan'] as List?) ?? const [];
    final totalsByCurrency =
        (_data['totals_by_currency'] as List?) ?? const [];
    final belowMarket = (_data['below_market_loans'] as List?) ?? const [];

    final empty = byMonth.isEmpty && byLoan.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        if (empty)
          _buildEmptyState(l10n)
        else ...[
          _buildCurrencyTotals(l10n, totalsByCurrency),
          const SizedBox(height: 24),
          _buildMonthlyChart(l10n, byMonth),
          const SizedBox(height: 24),
          _buildLoanTable(l10n, byLoan),
        ],
        if (belowMarket.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildBelowMarketCallout(l10n, belowMarket),
        ],
      ],
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.savings_outlined, size: 56, color: context.textFaint),
          const SizedBox(height: 12),
          Text(
            l10n.lendingInterestIncomeEmpty,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: context.textMuted),
          ),
        ],
      ),
    );
  }

  // ---------- per-currency totals (never summed across currencies) ----------

  Widget _buildCurrencyTotals(
      AppLocalizations l10n, List<dynamic> totals) {
    if (totals.isEmpty) return const SizedBox.shrink();
    // One card per currency, laid side-by-side; MXN and USD stay distinct.
    final cards = totals.whereType<Map>().map((raw) {
      final t = raw.cast<String, dynamic>();
      final currency = (t['currency'] ?? '').toString();
      final interest = (t['total_interest'] as num?)?.toDouble() ?? 0;
      final principal = (t['total_principal'] as num?)?.toDouble() ?? 0;
      final payments = (t['payments_count'] as num?)?.toInt() ?? 0;
      return _currencyTotalCard(
          l10n, currency, interest, principal, payments);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.lendingInterestIncomeTotalsByCurrency),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: cards,
        ),
      ],
    );
  }

  Widget _currencyTotalCard(AppLocalizations l10n, String currency,
      double interest, double principal, int payments) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            currency,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: context.textSubtle,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _moneyDisplay(interest, currency),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: context.positive,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            l10n.lendingInterestIncomeInterestReceived,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
          const SizedBox(height: 10),
          _miniStat(l10n.lendingInterestIncomePrincipalReceived,
              _moneyDisplay(principal, currency)),
          const SizedBox(height: 4),
          _miniStat(l10n.lendingInterestIncomePaymentsCount, '$payments'),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(fontSize: 11, color: context.textMuted)),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: context.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  // ---------- per-month bar ----------

  Widget _buildMonthlyChart(AppLocalizations l10n, List<dynamic> byMonth) {
    final rows = byMonth.whereType<Map>().map((m) {
      final r = m.cast<String, dynamic>();
      return (
        month: (r['month'] ?? '').toString(),
        interest: (r['interest_received'] as num?)?.toDouble() ?? 0,
      );
    }).where((r) => r.month.isNotEmpty).toList();

    if (rows.isEmpty) return const SizedBox.shrink();

    // The months can mix currencies; the bar is a relative magnitude
    // view (longest = max), so we don't print a currency on the bars
    // themselves — the per-currency totals above carry the labelled money.
    final maxInterest = rows
        .map((r) => r.interest)
        .fold<double>(0, (a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.lendingInterestIncomeByMonth),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            children: [
              for (final r in rows) ...[
                _monthBar(r.month, r.interest, maxInterest),
                if (r != rows.last) const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _monthBar(String month, double interest, double maxInterest) {
    // YYYY-MM → "Mon 'YY" for a compact axis label.
    String label = month;
    final parsed = DateTime.tryParse('$month-01');
    if (parsed != null) {
      label = DateFormat("MMM ''yy").format(parsed);
    }
    final fraction = maxInterest > 0 ? (interest / maxInterest) : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: context.tint(0.06),
              valueColor: AlwaysStoppedAnimation(context.positive),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 84,
          child: Text(
            // No currency symbol here (months may mix) — a plain magnitude.
            NumberFormat('#,##0.00').format(interest.abs() < 0.005 ? 0 : interest),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  // ---------- per-loan table ----------

  Widget _buildLoanTable(AppLocalizations l10n, List<dynamic> byLoan) {
    final rows = byLoan.whereType<Map>().map((m) => m.cast<String, dynamic>());
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.lendingInterestIncomeByLoan),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            children: [
              _loanTableHeader(l10n),
              for (final r in rows) _loanTableRow(r),
            ],
          ),
        ),
      ],
    );
  }

  Widget _loanTableHeader(AppLocalizations l10n) {
    Widget h(String t, {TextAlign align = TextAlign.start, int flex = 1}) {
      return Expanded(
        flex: flex,
        child: Text(
          t,
          textAlign: align,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: context.textSubtle,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.hairline)),
      ),
      child: Row(
        children: [
          h(l10n.lendingInterestIncomeBorrower, flex: 3),
          h(l10n.lendingInterestIncomeInterestReceived,
              align: TextAlign.right, flex: 2),
          h(l10n.lendingInterestIncomePrincipalReceived,
              align: TextAlign.right, flex: 2),
          h(l10n.lendingInterestIncomePaymentsCount,
              align: TextAlign.right, flex: 1),
        ],
      ),
    );
  }

  Widget _loanTableRow(Map<String, dynamic> r) {
    final borrower = (r['borrower_name'] ?? '').toString();
    final currency = (r['currency'] ?? 'USD').toString();
    final interest = (r['interest_received'] as num?)?.toDouble() ?? 0;
    final principal = (r['principal_received'] as num?)?.toDouble() ?? 0;
    final payments = (r['payments_count'] as num?)?.toInt() ?? 0;

    Widget cell(String t,
        {TextAlign align = TextAlign.start,
        int flex = 1,
        Color? color,
        FontWeight weight = FontWeight.w600}) {
      return Expanded(
        flex: flex,
        child: Text(
          t,
          textAlign: align,
          style: TextStyle(
            fontSize: 12,
            fontWeight: weight,
            color: color ?? context.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          // Borrower keeps its native currency tag so a mixed table is
          // unambiguous about which money each row is in.
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  borrower,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(currency,
                    style:
                        TextStyle(fontSize: 10, color: context.textSubtle)),
              ],
            ),
          ),
          cell(_money(interest, currency),
              align: TextAlign.right,
              flex: 2,
              color: context.positive,
              weight: FontWeight.w700),
          cell(_money(principal, currency), align: TextAlign.right, flex: 2),
          cell('$payments', align: TextAlign.right, flex: 1),
        ],
      ),
    );
  }

  // ---------- §7872 below-market callout ----------

  Widget _buildBelowMarketCallout(
      AppLocalizations l10n, List<dynamic> belowMarket) {
    final accent = context.warning;
    final loans =
        belowMarket.whereType<Map>().map((m) => m.cast<String, dynamic>());
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.accentSoft(accent),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.accentBorder(accent)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gavel_outlined, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.lendingInterestIncomeBelowMarketTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.lendingInterestIncomeBelowMarketBody,
            style: TextStyle(
                fontSize: 12, color: context.textMuted, height: 1.35),
          ),
          const SizedBox(height: 12),
          for (final loan in loans) _belowMarketRow(loan),
        ],
      ),
    );
  }

  Widget _belowMarketRow(Map<String, dynamic> loan) {
    final name = (loan['borrower_name'] ?? '').toString();
    final currency = (loan['currency'] ?? 'USD').toString();
    final principal = (loan['principal'] as num?)?.toDouble() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
                color: context.warning, shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary),
            ),
          ),
          Text(
            _moneyDisplay(principal, currency),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
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
