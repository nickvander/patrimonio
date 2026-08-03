/// Pure model + layout for the cash-flow Sankey diagram.
///
/// Nothing here touches a `BuildContext`, a color or a `NumberFormat`: the
/// widget injects already-localized node labels and does its own theming, so
/// every honesty-critical step (which months are in the window, per-row FX
/// before summing, what happens when income can't be attributed) is unit
/// testable on its own.
///
/// ## The money contract
///
/// Every flow width in a diagram is expressed in ONE reporting unit. The
/// `/dashboard/trends` and `/dashboard/spending-by-category` endpoints both
/// return USD already normalized PER ROW at each transaction's own-date
/// USD→MXN rate (backend `USD_MXN_ROW_RATE_SQL`), so those amounts are scaled
/// by a single [conversionFactor] (USD → the reporting currency). Amounts that
/// are still native — income transaction rows, FX-transfer legs — go through
/// [convertCurrency] individually BEFORE being summed. Mixed-currency sums are
/// the house's #1 shipped bug class; there is no code path here that adds a
/// raw MXN figure to a USD one.
library;

import 'dart:ui' show Offset, Path, Rect, Size, TextAlign;

import 'package:flutter/foundation.dart';

import 'category.dart';
import 'currency.dart';
import 'transaction_display.dart';

/// What a node represents. Drives only presentation (color/emphasis) in the
/// widget — the layout is kind-agnostic.
enum SankeyNodeKind {
  /// A named income source (or the "Other income" residual), or the single
  /// unattributed "Income" node when sources can't be resolved.
  incomeSource,

  /// The central pool every source feeds and every destination drains.
  hub,

  /// One spending category (or the "Uncategorized" residual).
  category,

  /// Net cash moved into investments over the window.
  invested,

  /// What the period did not spend — the surplus.
  saved,

  /// An inflow that is NOT income: savings drawn down to cover a deficit, or
  /// net cash coming back out of investments.
  drawdown,

  /// A currency endpoint of the cross-border band ("USD" / "MXN").
  fxEndpoint,

  /// The explicit conversion node between two currency endpoints.
  fxConversion,
}

@immutable
class SankeyNode {
  const SankeyNode({
    required this.id,
    required this.label,
    required this.depth,
    required this.value,
    required this.kind,
    this.seriesIndex,
  });

  /// Stable identity used by links and by the layout maps.
  final String id;

  /// Already-localized display label.
  final String label;

  /// Column index, 0-based, left to right.
  final int depth;

  /// Throughput in the reporting unit. Always >= 0.
  final double value;

  final SankeyNodeKind kind;

  /// Palette slot for `context.chartSeries(i)`; null means the widget picks a
  /// semantic color from [kind].
  final int? seriesIndex;
}

@immutable
class SankeyLink {
  const SankeyLink({
    required this.source,
    required this.target,
    required this.value,
  });

  final String source;
  final String target;

  /// Flow magnitude in the reporting unit. Always > 0.
  final double value;
}

@immutable
class SankeyDiagram {
  const SankeyDiagram({
    required this.nodes,
    required this.links,
    required this.total,
  });

  static const SankeyDiagram empty = SankeyDiagram(
    nodes: <SankeyNode>[],
    links: <SankeyLink>[],
    total: 0,
  );

  final List<SankeyNode> nodes;
  final List<SankeyLink> links;

  /// Throughput of the busiest column — the denominator every flow's "share
  /// of the period" is quoted against.
  final double total;

  bool get isEmpty => links.isEmpty;

  int get depthCount => nodes.isEmpty
      ? 0
      : nodes.map((n) => n.depth).reduce((a, b) => a > b ? a : b) + 1;

  SankeyNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }
}

/// Localized node labels, injected so this file stays `BuildContext`-free.
@immutable
class CashFlowSankeyLabels {
  const CashFlowSankeyLabels({
    required this.income,
    required this.otherIncome,
    required this.moneyIn,
    required this.saved,
    required this.invested,
    required this.fromSavings,
    required this.fromInvestments,
    required this.uncategorized,
    required this.fxConversion,
  });

  final String income;
  final String otherIncome;
  final String moneyIn;
  final String saved;
  final String invested;
  final String fromSavings;
  final String fromInvestments;
  final String uncategorized;
  final String fxConversion;
}

/// Everything the card needs to draw and narrate the period.
@immutable
class CashFlowSankeyData {
  const CashFlowSankeyData({
    required this.main,
    required this.fx,
    required this.income,
    required this.spending,
    required this.invested,
    required this.net,
    required this.incomeAttributed,
    required this.monthKeys,
    required this.fxTransferCount,
    required this.fxSent,
    required this.fxReceived,
  });

  static const CashFlowSankeyData empty = CashFlowSankeyData(
    main: SankeyDiagram.empty,
    fx: SankeyDiagram.empty,
    income: 0,
    spending: 0,
    invested: 0,
    net: 0,
    incomeAttributed: false,
    monthKeys: <String>[],
    fxTransferCount: 0,
    fxSent: <String, double>{},
    fxReceived: <String, double>{},
  );

  /// Income sources → the pool → spending / invested / saved.
  final SankeyDiagram main;

  /// The cross-border band: currency → conversion → currency. Empty when the
  /// user has no matched cross-currency transfers in the window.
  final SankeyDiagram fx;

  /// Period totals in the REPORTING unit, matching what the cash-flow tab's
  /// [MonthlyCashFlowCard] shows for the same period.
  final double income;
  final double spending;
  final double invested;

  /// `income + money out of investments − spending − money into investments`.
  /// Positive → a "Saved" outflow; negative → a "From savings" inflow.
  final double net;

  /// False when income could not be split into named sources and the diagram
  /// therefore shows one honest, unattributed "Income" node.
  final bool incomeAttributed;

  /// `YYYY-MM` buckets the figures cover, ascending.
  final List<String> monthKeys;

  /// How many matched cross-currency transfers fed [fx].
  final int fxTransferCount;

  /// Native (unconverted) totals per currency, for the readout: what left the
  /// source side and what landed on the destination side. Never summed
  /// together — they are quoted side by side with their own ISO codes.
  final Map<String, double> fxSent;
  final Map<String, double> fxReceived;

  bool get isEmpty => main.isEmpty && fx.isEmpty;
}

/// A named income contributor resolved from the transactions list.
@immutable
class IncomeSourceSlice {
  const IncomeSourceSlice(this.label, this.amount);
  final String label;
  final double amount;
}

/// Amounts below this (in the reporting unit) are treated as rounding dust and
/// never become their own node — a 0.004 residual bucket is noise, not a flow.
const double kSankeyEpsilon = 0.005;

/// Selects the `YYYY-MM` buckets a period covers, mirroring
/// `MonthlyCashFlowCard`'s own selection so the two cards can never disagree:
/// an aggregated window (3 months / YTD) sums every month in [trends], a
/// single-month period headlines [selectedMonthIso] when present, else the
/// latest month returned.
List<String> sankeyMonthKeys({
  required List<Map<String, dynamic>> trends,
  required String? selectedMonthIso,
  required bool aggregate,
}) {
  final months = <String>[
    for (final row in trends)
      if (row['month'] is String) row['month'] as String,
  ];
  if (months.isEmpty) return const <String>[];
  if (aggregate) return months;
  if (selectedMonthIso != null && months.contains(selectedMonthIso)) {
    return <String>[selectedMonthIso];
  }
  return <String>[months.last];
}

/// Whether a transaction row counts as household INCOME, mirroring the
/// backend's `cash_flow_trends` predicate as closely as a client can: positive
/// amount, effective category outside the internal-transfer/investment set,
/// and not a credit-card-payment or tax-refund leg (a return of the user's own
/// money). The row-level anti-joins the backend also applies — inflows into a
/// liability account, split parents, loan legs, confirmed FX pairs — need
/// server-side joins we don't have here, which is exactly why
/// [attributeIncomeSources] refuses to attribute at all when its total
/// overshoots the authoritative one.
bool isIncomeRow(Map tx) {
  final amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
  if (amount <= 0) return false;
  final userCat = tx['user_category']?.toString().trim() ?? '';
  final effCat =
      (userCat.isNotEmpty ? userCat : (tx['category']?.toString() ?? ''))
          .toUpperCase();
  if (effCat == 'TRANSFER_IN' ||
      effCat == 'TRANSFER_OUT' ||
      effCat == 'TRANSFER' ||
      effCat == 'INVESTMENT') {
    return false;
  }
  final detailed = tx['category_detailed']?.toString() ?? '';
  if (detailed == 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT' ||
      detailed == 'INCOME_TAX_REFUND') {
    return false;
  }
  return true;
}

/// Split [incomeTotal] into named sources, or return `null` when the loaded
/// transactions cannot honestly support an attribution.
///
/// This deliberately fails closed. Three gates must all pass:
///
/// 1. **Coverage** — the loaded list is a trailing page, so it may start after
///    the window does. Attribution is only attempted when some loaded row
///    predates the window's first day, which proves the window is fully
///    inside the page.
/// 2. **Non-overshoot** — the client can't replicate every server-side
///    anti-join, so the attributed sum is compared against the authoritative
///    [incomeTotal]. Overshooting past a tolerance means we're counting rows
///    the backend excluded; rather than guess which, the whole attribution is
///    abandoned.
/// 3. **Something to name** — at least one row survives.
///
/// When it succeeds, the named slices are capped at [maxSources] and the
/// remainder (unnamed rows, the tail past the cap, and anything the client
/// simply didn't see) becomes ONE honest "Other income" bucket, so the slices
/// always sum to exactly [incomeTotal]. Nothing is ever scaled to fit.
List<IncomeSourceSlice>? attributeIncomeSources({
  required List<dynamic> transactions,
  required List<String> monthKeys,
  required double incomeTotal,
  required String targetCurrency,
  required double usdMxnRate,
  required String otherLabel,
  int maxSources = 5,
}) {
  if (incomeTotal <= kSankeyEpsilon) return null;
  if (transactions.isEmpty || monthKeys.isEmpty) return null;

  // Gate 1: coverage. ISO dates sort lexicographically, so a plain string
  // compare answers "did the page reach past the start of the window?".
  final sortedKeys = [...monthKeys]..sort();
  final windowStart = '${sortedKeys.first}-01';
  var reachesBeforeWindow = false;
  final keySet = sortedKeys.toSet();

  final byName = <String, double>{};
  var attributed = 0.0;
  final tolerance = incomeTotal * 0.02 > 1.0 ? incomeTotal * 0.02 : 1.0;

  for (final raw in transactions) {
    if (raw is! Map) continue;
    final date = raw['date']?.toString();
    if (date == null || date.length < 7) continue;
    if (date.compareTo(windowStart) < 0) reachesBeforeWindow = true;
    if (!keySet.contains(date.substring(0, 7))) continue;
    if (!isIncomeRow(raw)) continue;

    // Per-row FX before summing: an MXN payroll deposit is converted on its
    // own before it joins a USD-denominated total.
    final amount = ((raw['amount'] as num?)?.toDouble() ?? 0.0).abs();
    final converted = convertCurrency(
      amount,
      from: (raw['currency'] ?? targetCurrency).toString(),
      to: targetCurrency,
      usdMxnRate: usdMxnRate,
    );
    if (converted <= 0) continue;
    attributed += converted;
    final label = displayLabel(Map<String, dynamic>.from(raw));
    final key = label.trim().isEmpty ? otherLabel : label.trim();
    byName[key] = (byName[key] ?? 0.0) + converted;
  }

  if (!reachesBeforeWindow) return null; // Gate 1 failed.
  if (byName.isEmpty || attributed <= kSankeyEpsilon) return null; // Gate 3.
  if (attributed > incomeTotal + tolerance) return null; // Gate 2.

  final ranked = byName.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final named = <IncomeSourceSlice>[
    for (final e in ranked.take(maxSources)) IncomeSourceSlice(e.key, e.value),
  ];
  final namedSum = named.fold<double>(0, (s, e) => s + e.amount);
  final residual = incomeTotal - namedSum;
  if (residual > kSankeyEpsilon) {
    named.add(IncomeSourceSlice(otherLabel, residual));
  }
  return named;
}

/// Build the diagrams for one cash-flow period.
///
/// [trends] are raw `/dashboard/trends` rows (USD); [categoryData] is the raw
/// `/dashboard/spending-by-category` response (USD); [transactions],
/// [fxTransfers] are the lists the dashboard already holds. [conversionFactor]
/// scales USD into [targetCurrency]; [usdMxnRate] converts the still-native
/// amounts.
CashFlowSankeyData buildCashFlowSankey({
  required List<Map<String, dynamic>> trends,
  required String? selectedMonthIso,
  required bool aggregate,
  required Map<String, dynamic>? categoryData,
  required List<dynamic> transactions,
  required List<dynamic> fxTransfers,
  required double conversionFactor,
  required String targetCurrency,
  required double usdMxnRate,
  required CashFlowSankeyLabels labels,
  int maxIncomeSources = 5,
  int maxCategories = 8,
}) {
  final monthKeys = sankeyMonthKeys(
    trends: trends,
    selectedMonthIso: selectedMonthIso,
    aggregate: aggregate,
  );
  final fx = _buildFxDiagram(
    fxTransfers: fxTransfers,
    monthKeys: monthKeys,
    targetCurrency: targetCurrency,
    usdMxnRate: usdMxnRate,
    label: labels.fxConversion,
  );
  if (monthKeys.isEmpty) {
    return CashFlowSankeyData(
      main: SankeyDiagram.empty,
      fx: fx.diagram,
      income: 0,
      spending: 0,
      invested: 0,
      net: 0,
      incomeAttributed: false,
      monthKeys: const <String>[],
      fxTransferCount: fx.count,
      fxSent: fx.sent,
      fxReceived: fx.received,
    );
  }

  final keySet = monthKeys.toSet();
  var income = 0.0;
  var spendingTrend = 0.0;
  var invested = 0.0;
  for (final row in trends) {
    if (!keySet.contains(row['month'])) continue;
    income += (row['income'] as num?)?.toDouble() ?? 0.0;
    spendingTrend += (row['spending'] as num?)?.toDouble() ?? 0.0;
    invested += (row['invested'] as num?)?.toDouble() ?? 0.0;
  }
  // Single scale from the endpoints' USD into the reporting currency.
  income *= conversionFactor;
  spendingTrend *= conversionFactor;
  invested *= conversionFactor;

  // --- Outflow breakdown -------------------------------------------------
  // `/dashboard/spending-by-category` applies the SAME hygiene as
  // `/dashboard/trends` (same anti-joins, same non-cash-flow category set),
  // so its category totals reconcile with the trend row's `spending` for the
  // same months. Anything the breakdown doesn't cover becomes an explicit
  // "Uncategorized" flow — never silently dropped, and never scaled to fit.
  final categorySlices = <String, double>{};
  final categories =
      (categoryData?['categories'] as List<dynamic>?) ?? const <dynamic>[];
  for (final raw in categories) {
    if (raw is! Map) continue;
    final code = (raw['category'] ?? '').toString();
    var sum = 0.0;
    for (final m in (raw['monthly'] as List<dynamic>?) ?? const <dynamic>[]) {
      if (m is! Map) continue;
      if (!keySet.contains(m['month'])) continue;
      sum += (m['amount'] as num?)?.toDouble() ?? 0.0;
    }
    sum *= conversionFactor;
    if (sum <= kSankeyEpsilon) continue;
    categorySlices[code] = (categorySlices[code] ?? 0.0) + sum;
  }

  var ranked = categorySlices.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (ranked.length > maxCategories) {
    // Fold the tail into the backend's own OTHER rollup key so the label set
    // stays stable instead of sprouting a second "Other".
    final tail = ranked
        .skip(maxCategories)
        .fold<double>(0, (s, e) => s + e.value);
    final kept = <String, double>{
      for (final e in ranked.take(maxCategories)) e.key: e.value,
    };
    kept['OTHER'] = (kept['OTHER'] ?? 0.0) + tail;
    ranked = kept.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  final outflows = <_Slice>[
    for (final e in ranked)
      _Slice(
        id: 'cat:${e.key}',
        label: e.key == 'UNCATEGORIZED'
            ? labels.uncategorized
            : prettyCategory(primary: e.key),
        value: e.value,
        kind: SankeyNodeKind.category,
      ),
  ];
  final categorised = outflows.fold<double>(0, (s, e) => s + e.value);
  final unreconciled = spendingTrend - categorised;
  if (unreconciled > kSankeyEpsilon) {
    outflows.add(
      _Slice(
        id: 'cat:UNRECONCILED',
        label: labels.uncategorized,
        value: unreconciled,
        kind: SankeyNodeKind.category,
      ),
    );
  }
  // A Sankey node's value IS the sum of its flows; quoting a spending total
  // the drawn bands don't add up to would be the lie this card exists to
  // avoid. In practice the two endpoints agree and this equals `spending`.
  final spending = outflows.fold<double>(0, (s, e) => s + e.value);

  // --- Investing + the surplus/deficit balance --------------------------
  // `invested` is net cash into investments (buys +, sells −) and is peeled
  // out of BOTH income and spending upstream, so it is its own outflow when
  // positive and its own inflow when negative.
  final investedOut = invested > 0 ? invested : 0.0;
  final investedIn = invested < 0 ? -invested : 0.0;
  final net = income + investedIn - spending - investedOut;

  // --- Income sources ----------------------------------------------------
  final attributed = attributeIncomeSources(
    transactions: transactions,
    monthKeys: monthKeys,
    incomeTotal: income,
    targetCurrency: targetCurrency,
    usdMxnRate: usdMxnRate,
    otherLabel: labels.otherIncome,
    maxSources: maxIncomeSources,
  );
  final inflows = <_Slice>[];
  if (attributed != null) {
    for (var i = 0; i < attributed.length; i++) {
      inflows.add(
        _Slice(
          id: 'src:$i',
          label: attributed[i].label,
          value: attributed[i].amount,
          kind: SankeyNodeKind.incomeSource,
          seriesIndex: i,
        ),
      );
    }
  } else if (income > kSankeyEpsilon) {
    inflows.add(
      _Slice(
        id: 'src:0',
        label: labels.income,
        value: income,
        kind: SankeyNodeKind.incomeSource,
        seriesIndex: 0,
      ),
    );
  }
  if (investedIn > kSankeyEpsilon) {
    inflows.add(
      _Slice(
        id: 'src:divest',
        label: labels.fromInvestments,
        value: investedIn,
        kind: SankeyNodeKind.drawdown,
      ),
    );
  }
  if (net < -kSankeyEpsilon) {
    inflows.add(
      _Slice(
        id: 'src:drawdown',
        label: labels.fromSavings,
        value: -net,
        kind: SankeyNodeKind.drawdown,
      ),
    );
  }

  if (investedOut > kSankeyEpsilon) {
    outflows.add(
      _Slice(
        id: 'out:invested',
        label: labels.invested,
        value: investedOut,
        kind: SankeyNodeKind.invested,
      ),
    );
  }
  if (net > kSankeyEpsilon) {
    outflows.add(
      _Slice(
        id: 'out:saved',
        label: labels.saved,
        value: net,
        kind: SankeyNodeKind.saved,
      ),
    );
  }

  final main = _assembleThreeColumn(
    inflows: inflows,
    outflows: outflows,
    hubId: 'hub',
    hubLabel: labels.moneyIn,
    hubKind: SankeyNodeKind.hub,
  );

  return CashFlowSankeyData(
    main: main,
    fx: fx.diagram,
    income: income,
    spending: spending,
    invested: invested,
    net: net,
    incomeAttributed: attributed != null,
    monthKeys: monthKeys,
    fxTransferCount: fx.count,
    fxSent: fx.sent,
    fxReceived: fx.received,
  );
}

@immutable
class _Slice {
  const _Slice({
    required this.id,
    required this.label,
    required this.value,
    required this.kind,
    this.seriesIndex,
  });
  final String id;
  final String label;
  final double value;
  final SankeyNodeKind kind;
  final int? seriesIndex;
}

/// sources → hub → destinations, with the hub sized by whichever side carries
/// more (they are equal by construction; `max` only guards float dust).
SankeyDiagram _assembleThreeColumn({
  required List<_Slice> inflows,
  required List<_Slice> outflows,
  required String hubId,
  required String hubLabel,
  required SankeyNodeKind hubKind,
}) {
  final inTotal = inflows.fold<double>(0, (s, e) => s + e.value);
  final outTotal = outflows.fold<double>(0, (s, e) => s + e.value);
  final hubTotal = inTotal > outTotal ? inTotal : outTotal;
  if (hubTotal <= kSankeyEpsilon) return SankeyDiagram.empty;

  final nodes = <SankeyNode>[
    for (final s in inflows)
      SankeyNode(
        id: s.id,
        label: s.label,
        depth: 0,
        value: s.value,
        kind: s.kind,
        seriesIndex: s.seriesIndex,
      ),
    SankeyNode(
      id: hubId,
      label: hubLabel,
      depth: 1,
      value: hubTotal,
      kind: hubKind,
    ),
    for (var i = 0; i < outflows.length; i++)
      SankeyNode(
        id: outflows[i].id,
        label: outflows[i].label,
        depth: 2,
        value: outflows[i].value,
        kind: outflows[i].kind,
        seriesIndex: outflows[i].seriesIndex ?? i,
      ),
  ];
  final links = <SankeyLink>[
    for (final s in inflows)
      SankeyLink(source: s.id, target: hubId, value: s.value),
    for (final s in outflows)
      SankeyLink(source: hubId, target: s.id, value: s.value),
  ];
  return SankeyDiagram(nodes: nodes, links: links, total: hubTotal);
}

@immutable
class _FxBuild {
  const _FxBuild(this.diagram, this.count, this.sent, this.received);
  final SankeyDiagram diagram;
  final int count;
  final Map<String, double> sent;
  final Map<String, double> received;
}

/// The differentiator: money crossing currencies drawn as an explicit
/// conversion node rather than vanishing into a total.
///
/// Sourced ONLY from `cash_fx_transfers` rows that the backend actually
/// matched into a pair. An unpaired cross-currency movement is invisible to
/// this endpoint, so none is invented — the card's caption says how many
/// matched transfers the band covers and that unmatched ones aren't shown.
///
/// Both sides of the band are sized by the SOURCE leg converted at today's
/// rate. Sizing the destination side by its own leg would render pure
/// USD/MXN drift since the transfer date as if it were a conversion fee (or,
/// when the peso moved the other way, as a phantom gain). The real
/// implied-vs-spot comparison already has a home in
/// `CrossCurrencyTransfersCard`; this band answers "how much crossed", and
/// the readout quotes both native legs with their own ISO codes.
_FxBuild _buildFxDiagram({
  required List<dynamic> fxTransfers,
  required List<String> monthKeys,
  required String targetCurrency,
  required double usdMxnRate,
  required String label,
}) {
  const emptyBuild = _FxBuild(
    SankeyDiagram.empty,
    0,
    <String, double>{},
    <String, double>{},
  );
  if (fxTransfers.isEmpty || monthKeys.isEmpty) return emptyBuild;
  final keySet = monthKeys.toSet();

  final byPair = <String, double>{};
  final pairOrder = <String>[];
  final sent = <String, double>{};
  final received = <String, double>{};
  var count = 0;

  for (final raw in fxTransfers) {
    if (raw is! Map) continue;
    final date = raw['source_date']?.toString();
    if (date == null || date.length < 7) continue;
    if (!keySet.contains(date.substring(0, 7))) continue;
    final src = (raw['source_currency'] ?? '').toString().toUpperCase();
    final dst = (raw['dest_currency'] ?? '').toString().toUpperCase();
    if (src.isEmpty || dst.isEmpty || src == dst) continue;
    final srcAmount = ((raw['source_amount'] as num?)?.toDouble() ?? 0.0).abs();
    final dstAmount = ((raw['dest_amount'] as num?)?.toDouble() ?? 0.0).abs();
    if (srcAmount <= 0) continue;
    // Per-leg conversion before summing.
    final value = convertCurrency(
      srcAmount,
      from: src,
      to: targetCurrency,
      usdMxnRate: usdMxnRate,
    );
    if (value <= 0) continue;
    final pair = '$src>$dst';
    if (!byPair.containsKey(pair)) pairOrder.add(pair);
    byPair[pair] = (byPair[pair] ?? 0.0) + value;
    sent[src] = (sent[src] ?? 0.0) + srcAmount;
    received[dst] = (received[dst] ?? 0.0) + dstAmount;
    count++;
  }

  if (byPair.isEmpty) return emptyBuild;

  final srcTotals = <String, double>{};
  final dstTotals = <String, double>{};
  for (final pair in pairOrder) {
    final parts = pair.split('>');
    srcTotals[parts[0]] = (srcTotals[parts[0]] ?? 0.0) + byPair[pair]!;
    dstTotals[parts[1]] = (dstTotals[parts[1]] ?? 0.0) + byPair[pair]!;
  }
  final total = byPair.values.fold<double>(0, (s, e) => s + e);

  final nodes = <SankeyNode>[
    for (final e in srcTotals.entries)
      SankeyNode(
        id: 'fxout:${e.key}',
        label: e.key,
        depth: 0,
        value: e.value,
        kind: SankeyNodeKind.fxEndpoint,
      ),
    SankeyNode(
      id: 'fx',
      label: label,
      depth: 1,
      value: total,
      kind: SankeyNodeKind.fxConversion,
    ),
    for (final e in dstTotals.entries)
      SankeyNode(
        id: 'fxin:${e.key}',
        label: e.key,
        depth: 2,
        value: e.value,
        kind: SankeyNodeKind.fxEndpoint,
      ),
  ];
  final links = <SankeyLink>[
    for (final e in srcTotals.entries)
      SankeyLink(source: 'fxout:${e.key}', target: 'fx', value: e.value),
    for (final e in dstTotals.entries)
      SankeyLink(source: 'fx', target: 'fxin:${e.key}', value: e.value),
  ];

  return _FxBuild(
    SankeyDiagram(nodes: nodes, links: links, total: total),
    count,
    sent,
    received,
  );
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

@immutable
class SankeyBand {
  const SankeyBand({
    required this.link,
    required this.sourceRect,
    required this.targetRect,
    required this.sourceTop,
    required this.targetTop,
    required this.thickness,
  });

  final SankeyLink link;
  final Rect sourceRect;
  final Rect targetRect;

  /// Where the band leaves the source node / enters the target node.
  final double sourceTop;
  final double targetTop;
  final double thickness;
}

@immutable
class SankeyLayout {
  const SankeyLayout({
    required this.nodeRects,
    required this.bands,
    required this.scale,
  });

  static const SankeyLayout empty = SankeyLayout(
    nodeRects: <String, Rect>{},
    bands: <SankeyBand>[],
    scale: 0,
  );

  final Map<String, Rect> nodeRects;
  final List<SankeyBand> bands;

  /// Reporting-units → logical pixels. ONE scale for the whole diagram: a
  /// per-column scale would make two bands of equal width mean different
  /// amounts, which is the whole point of a Sankey.
  final double scale;

  bool get isEmpty => bands.isEmpty;
}

/// Deterministic layout: columns are evenly spaced between the gutters, each
/// column is vertically centred, and every value shares one [SankeyLayout.scale].
SankeyLayout layoutSankey(
  SankeyDiagram diagram, {
  required double width,
  required double height,
  required double leftGutter,
  required double rightGutter,
  double top = 0,
  double nodeWidth = 10,
  double nodeGap = 10,
  double minThickness = 1.5,
}) {
  if (diagram.isEmpty || height <= 0) return SankeyLayout.empty;
  final depthCount = diagram.depthCount;
  if (depthCount < 2) return SankeyLayout.empty;

  final bandWidth = width - leftGutter - rightGutter - nodeWidth;
  if (bandWidth <= 0) return SankeyLayout.empty;

  final byDepth = <int, List<SankeyNode>>{};
  for (final n in diagram.nodes) {
    (byDepth[n.depth] ??= <SankeyNode>[]).add(n);
  }

  // One shared scale: the tightest column wins so nothing overflows.
  var scale = double.infinity;
  for (final entry in byDepth.entries) {
    final column = entry.value;
    final total = column.fold<double>(0, (s, n) => s + n.value);
    if (total <= 0) continue;
    final gaps = (column.length - 1) * nodeGap;
    final usable = height - gaps;
    if (usable <= 0) return SankeyLayout.empty;
    final s = usable / total;
    if (s < scale) scale = s;
  }
  if (!scale.isFinite || scale <= 0) return SankeyLayout.empty;

  final nodeRects = <String, Rect>{};
  for (final entry in byDepth.entries) {
    final depth = entry.key;
    final column = entry.value;
    final heights = <double>[
      for (final n in column) _atLeast(n.value * scale, 1.0),
    ];
    final columnHeight =
        heights.fold<double>(0, (s, h) => s + h) +
        (column.length - 1) * nodeGap;
    var y = top + (height - columnHeight) / 2;
    final x = leftGutter + (bandWidth * depth) / (depthCount - 1);
    for (var i = 0; i < column.length; i++) {
      nodeRects[column[i].id] = Rect.fromLTWH(x, y, nodeWidth, heights[i]);
      y += heights[i] + nodeGap;
    }
  }

  // Bands stack inside each node in link declaration order, so a source's
  // outgoing ribbons keep the same top-to-bottom order as its column.
  final sourceCursor = <String, double>{};
  final targetCursor = <String, double>{};
  final bands = <SankeyBand>[];
  for (final link in diagram.links) {
    final sr = nodeRects[link.source];
    final tr = nodeRects[link.target];
    if (sr == null || tr == null) continue;
    final thickness = _atLeast(link.value * scale, minThickness);
    final sTop = sr.top + (sourceCursor[link.source] ?? 0);
    final tTop = tr.top + (targetCursor[link.target] ?? 0);
    sourceCursor[link.source] = (sourceCursor[link.source] ?? 0) + thickness;
    targetCursor[link.target] = (targetCursor[link.target] ?? 0) + thickness;
    bands.add(
      SankeyBand(
        link: link,
        sourceRect: sr,
        targetRect: tr,
        sourceTop: sTop,
        targetTop: tTop,
        thickness: thickness,
      ),
    );
  }

  return SankeyLayout(nodeRects: nodeRects, bands: bands, scale: scale);
}

double _atLeast(double v, double floor) => v < floor ? floor : v;

/// The closed ribbon for one band — two cubic curves and two straight edges.
/// Shared by the painter and by hit-testing so what you tap is exactly what
/// you see.
Path sankeyBandPath(SankeyBand b) {
  final x0 = b.sourceRect.right;
  final x1 = b.targetRect.left;
  final cx = (x0 + x1) / 2;
  final sTop = b.sourceTop;
  final sBottom = b.sourceTop + b.thickness;
  final tTop = b.targetTop;
  final tBottom = b.targetTop + b.thickness;
  return Path()
    ..moveTo(x0, sTop)
    ..cubicTo(cx, sTop, cx, tTop, x1, tTop)
    ..lineTo(x1, tBottom)
    ..cubicTo(cx, tBottom, cx, sBottom, x0, sBottom)
    ..close();
}

/// Topmost band containing [point], or null. Iterates in reverse so the band
/// drawn last (on top) wins a tap in an overlap.
SankeyBand? sankeyBandAt(SankeyLayout layout, Offset point) {
  for (var i = layout.bands.length - 1; i >= 0; i--) {
    if (sankeyBandPath(layout.bands[i]).contains(point)) return layout.bands[i];
  }
  return null;
}

// ---------------------------------------------------------------------------
// Label layout
// ---------------------------------------------------------------------------
//
// A Sankey node's rect is VALUE-sized: a $26 slice of a $620 period is about
// one pixel tall. Centring a two-line label block on such a rect means the
// blocks of adjacent small nodes overprint each other into mush — which is
// exactly what shipped (4 of 6 value labels illegible at desktop width). So
// label placement is a separate, explicit pass with three jobs:
//
//   1. **Never overlap.** A post-layout pass per column pushes blocks apart
//      (forward, then backward off the bottom edge) so the placed rects are
//      pairwise disjoint by construction.
//   2. **Degrade deliberately.** When a column genuinely cannot fit every
//      block, the SMALLEST-value labels are dropped outright — their amount is
//      still reachable by tapping the band — rather than painted on top of a
//      neighbour.
//   3. **Stay inside the canvas.** Every rect is clamped into the paint box,
//      so nothing bleeds over the widgets below (a `CustomPaint` does not clip
//      by default; the painter also clips, belt and braces).
//
// It lives here, not in the painter, because it is pure geometry: the caller
// injects text measurement and gets back final strings + rects.

/// Vertical breathing room between two stacked label blocks.
const double kSankeyLabelGap = 3.0;

/// Vertical gap between a label's name line and its value line.
const double kSankeyLabelLineGap = 1.0;

/// Horizontal gap between a node bar and its label block.
const double kSankeyLabelInset = 4.0;

/// Text measurement injected into [layoutSankeyLabels] so the geometry stays
/// `BuildContext`-free (and unit-testable) while still using the real font
/// metrics of the styles the painter will draw with.
@immutable
class SankeyLabelMetrics {
  const SankeyLabelMetrics({
    required this.measureName,
    required this.measureValue,
    required this.nameHeight,
    required this.valueHeight,
  });

  /// Unconstrained width of a node-name string in the name style.
  final double Function(String text) measureName;

  /// Unconstrained width of a money string in the value style.
  final double Function(String text) measureValue;

  /// Single-line heights of the two styles.
  final double nameHeight;
  final double valueHeight;

  double get blockHeight => nameHeight + kSankeyLabelLineGap + valueHeight;
}

/// One node's label, measured, fitted and collision-resolved. [rect] is the
/// whole two-line block; the name occupies the top [SankeyLabelMetrics.nameHeight]
/// of it and the value the rest.
@immutable
class SankeyLabelPlacement {
  const SankeyLabelPlacement({
    required this.nodeId,
    required this.name,
    required this.value,
    required this.rect,
    required this.align,
  });

  final String nodeId;

  /// Display string for the node name — already middle-elided if it did not
  /// fit, so two sources sharing a long prefix stay distinguishable.
  final String name;

  /// Display string for the node value — exact money when it fits, compact
  /// only as the fallback.
  final String value;

  final Rect rect;
  final TextAlign align;
}

/// A block awaiting vertical placement inside one column.
@immutable
class SankeyLabelCandidate {
  const SankeyLabelCandidate({
    required this.nodeId,
    required this.left,
    required this.width,
    required this.height,
    required this.preferredCenterY,
    required this.priority,
  });

  final String nodeId;
  final double left;
  final double width;
  final double height;

  /// Where the block would sit with no neighbours — the node's own centre.
  final double preferredCenterY;

  /// Bigger wins when the column has to drop labels. The node's value.
  final double priority;
}

/// Place [candidates] inside `[minY, maxY]` so that **no two blocks overlap**.
///
/// Two phases:
///
/// * **Capacity** — if the blocks cannot all fit, the lowest-[priority] ones
///   are dropped until they do. Painting a label illegibly on top of another
///   is strictly worse than not painting it, and the tap readout still reports
///   the dropped node's amount.
/// * **Relaxation** — the survivors are sorted by preferred centre, pushed
///   down off each other (forward pass) and then pulled back up off the bottom
///   edge (backward pass). Because the survivors provably fit, the backward
///   pass never has to push anything above [minY], so the result is pairwise
///   disjoint.
///
/// Returned in top-to-bottom order.
List<SankeyLabelSlot> placeSankeyLabels(
  List<SankeyLabelCandidate> candidates, {
  required double minY,
  required double maxY,
  double gap = kSankeyLabelGap,
}) {
  if (candidates.isEmpty) return const <SankeyLabelSlot>[];
  // A hair of slack so float dust in the capacity check can never make the
  // backward pass clamp two blocks onto the same pixel.
  final available = maxY - minY - 0.5;
  if (available <= 0) return const <SankeyLabelSlot>[];

  final byPriority = [...candidates]
    ..sort((a, b) {
      final p = b.priority.compareTo(a.priority);
      return p != 0 ? p : a.nodeId.compareTo(b.nodeId);
    });
  final kept = <SankeyLabelCandidate>[];
  var used = 0.0;
  for (final c in byPriority) {
    final extra = c.height + (kept.isEmpty ? 0.0 : gap);
    if (used + extra > available) break;
    used += extra;
    kept.add(c);
  }
  if (kept.isEmpty) return const <SankeyLabelSlot>[];

  kept.sort((a, b) {
    final c = a.preferredCenterY.compareTo(b.preferredCenterY);
    return c != 0 ? c : a.nodeId.compareTo(b.nodeId);
  });

  final tops = <double>[];
  var cursor = minY;
  for (final c in kept) {
    var top = c.preferredCenterY - c.height / 2;
    if (top < cursor) top = cursor;
    tops.add(top);
    cursor = top + c.height + gap;
  }
  var limit = maxY;
  for (var i = kept.length - 1; i >= 0; i--) {
    var top = tops[i];
    if (top + kept[i].height > limit) top = limit - kept[i].height;
    if (top < minY) top = minY;
    tops[i] = top;
    limit = top - gap;
  }

  return <SankeyLabelSlot>[
    for (var i = 0; i < kept.length; i++)
      SankeyLabelSlot(
        candidate: kept[i],
        rect: Rect.fromLTWH(
          kept[i].left,
          tops[i],
          kept[i].width,
          kept[i].height,
        ),
      ),
  ];
}

/// A candidate plus the rect [placeSankeyLabels] resolved for it.
@immutable
class SankeyLabelSlot {
  const SankeyLabelSlot({required this.candidate, required this.rect});
  final SankeyLabelCandidate candidate;
  final Rect rect;
}

/// Shorten [text] from the MIDDLE until [measure] says it fits [maxWidth].
///
/// Tail-ellipsis ("Dividend received - AAPL" and "Dividend received - O
/// (monthly)" both collapsing to "Dividend received - …") defeats the entire
/// point of naming income sources — two different payers rendered as one
/// string. Keeping a head AND a tail keeps them distinguishable, because the
/// discriminating token in a bank label is almost always at the end.
///
/// The head/tail split is biased 45/55 toward the tail for that reason. The
/// search is a binary search over how many characters survive, so [measure] is
/// called O(log n) times.
String middleEllipsize(
  String text,
  double maxWidth,
  double Function(String) measure, {
  String ellipsis = '…',
}) {
  if (maxWidth <= 0) return '';
  if (text.isEmpty || measure(text) <= maxWidth) return text;

  final runes = text.runes.toList();
  final n = runes.length;
  String build(int keep) {
    if (keep <= 0) return ellipsis;
    final head = (keep * 0.45).round().clamp(0, keep);
    final tail = keep - head;
    return String.fromCharCodes(runes.take(head)) +
        ellipsis +
        String.fromCharCodes(runes.skip(n - tail));
  }

  var lo = 0;
  var hi = n - 1;
  var best = ellipsis;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    final candidate = build(mid);
    if (measure(candidate) <= maxWidth) {
      best = candidate;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

/// Money string for a node label: **exact** when it fits the gutter, compact
/// only when it doesn't.
///
/// The card reconciles with `MonthlyCashFlowCard` right above it, and
/// unconditional [compactMoney] made it print "$50.6" next to that card's
/// "$50.60" — a self-inflicted disagreement on the one thing this diagram
/// exists to corroborate. Exact money is preferred; compact is the fallback
/// that keeps a seven-figure MXN total from being ellipsized into a 10x
/// misread on a 68px phone gutter.
String sankeyLabelValueText(
  double value,
  String currency,
  double maxWidth,
  double Function(String) measure,
) {
  final exact = formatCurrencyAmount(value, currency);
  if (measure(exact) <= maxWidth) return exact;
  return compactMoney(value, currency);
}

/// Resolve every node label for [diagram] into a final string + a rect that
/// overlaps no other label and lies entirely inside [canvas].
///
/// Column rules:
/// * depth 0 — right-aligned in the left gutter;
/// * last depth — left-aligned in the right gutter;
/// * anything between (the pool, the FX conversion node) — centred over the
///   bar, dropping below it only when there is no room above, and clamped into
///   the canvas either way.
List<SankeyLabelPlacement> layoutSankeyLabels({
  required SankeyDiagram diagram,
  required SankeyLayout layout,
  required Size canvas,
  required double gutter,
  required String currency,
  required SankeyLabelMetrics metrics,
  double gap = kSankeyLabelGap,
}) {
  if (layout.isEmpty || diagram.depthCount < 2) {
    return const <SankeyLabelPlacement>[];
  }
  final last = diagram.depthCount - 1;
  final byDepth = <int, List<SankeyNode>>{};
  for (final n in diagram.nodes) {
    if (layout.nodeRects[n.id] == null) continue;
    (byDepth[n.depth] ??= <SankeyNode>[]).add(n);
  }

  final out = <SankeyLabelPlacement>[];
  final depths = byDepth.keys.toList()..sort();
  for (final depth in depths) {
    final column = byDepth[depth]!;
    final edge = depth == 0 || depth == last;
    final maxWidth = edge
        ? gutter - kSankeyLabelInset * 2
        : _middleLabelWidth(canvas.width, gutter);
    if (maxWidth < (edge ? 12.0 : 40.0)) continue;

    final texts = <String, ({String name, String value})>{};
    final candidates = <SankeyLabelCandidate>[];
    for (final node in column) {
      final rect = layout.nodeRects[node.id]!;
      texts[node.id] = (
        name: middleEllipsize(node.label, maxWidth, metrics.measureName),
        value: sankeyLabelValueText(
          node.value,
          currency,
          maxWidth,
          metrics.measureValue,
        ),
      );
      final height = metrics.blockHeight;
      final double left;
      final double centerY;
      if (edge) {
        left = depth == 0
            ? rect.left - kSankeyLabelInset - maxWidth
            : rect.right + kSankeyLabelInset;
        centerY = rect.center.dy;
      } else {
        left = (rect.center.dx - maxWidth / 2).clamp(
          gutter + kSankeyLabelInset,
          canvas.width - gutter - kSankeyLabelInset - maxWidth,
        );
        // Above the bar when it fits, otherwise below it. Either way the
        // placer clamps the block into the canvas, so the old "below the bar"
        // fallback can no longer paint the value on top of the caption
        // underneath the diagram.
        final above = rect.top - kSankeyLabelInset - height;
        centerY =
            (above >= 0 ? above : rect.bottom + kSankeyLabelInset) + height / 2;
      }
      candidates.add(
        SankeyLabelCandidate(
          nodeId: node.id,
          left: left,
          width: maxWidth,
          height: height,
          preferredCenterY: centerY,
          priority: node.value,
        ),
      );
    }

    final placed = placeSankeyLabels(
      candidates,
      minY: 0,
      maxY: canvas.height,
      gap: gap,
    );
    for (final p in placed) {
      final t = texts[p.candidate.nodeId]!;
      out.add(
        SankeyLabelPlacement(
          nodeId: p.candidate.nodeId,
          name: t.name,
          value: t.value,
          rect: p.rect,
          align: edge
              ? (depth == 0 ? TextAlign.right : TextAlign.left)
              : TextAlign.center,
        ),
      );
    }
  }
  return out;
}

/// Width for a middle-column label: wider than a gutter (the pool's name is
/// the longest string on the card) but never wide enough to reach into either
/// gutter, so a centred block can't collide with an edge-column one.
double _middleLabelWidth(double canvasWidth, double gutter) {
  final between = canvasWidth - gutter * 2 - kSankeyLabelInset * 2;
  final wanted = gutter * 1.6;
  return wanted < between ? wanted : between;
}
