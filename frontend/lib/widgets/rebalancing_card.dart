import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../components/allocation_heatmap.dart' show AllocationData;
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import 'skeleton.dart';

/// Canonical asset-class keys (contract C3-A / C4-A), in the selector
/// ordering the editor renders. `unclassified` is deliberately absent —
/// it is untargetable (backlog-4 decision #5) but stays in the actual-%
/// denominator so the card reconciles with the heatmap's headline total.
const List<String> kAllocationClassKeys = [
  'equity',
  'bonds',
  'cash',
  'crypto',
  'real_estate',
  'commodities',
  'other',
];

/// Drift band (percentage points) inside which a class reads "on target",
/// and the display-currency floor below which a move suggestion is worse
/// than silence (backlog-4 decision #10). Hardcoded — single owner.
const double kRebalanceBandPp = 2.0;
const double kRebalanceMinMoveUsd = 500.0;
const int kRebalanceMaxMoveLines = 3;

/// Result of reading the `allocation_targets` setting (contract C4-A).
///
/// Exactly one of three shapes:
///  • unset      — setting never written / cleared (JSON `null`);
///  • malformed  — present but violating the contract (bad sum, non-numeric
///    values, wrong envelope) → the card shows a repair state instead of
///    garbage bars; [targets] carries whatever valid per-class values could
///    be salvaged, as the editor's best-guess prefill;
///  • ok         — [targets] is the validated percentage map (absent
///    class = target 0).
class AllocationTargetsParse {
  final bool unset;
  final bool malformed;
  final Map<String, double> targets;

  const AllocationTargetsParse._(this.unset, this.malformed, this.targets);

  const AllocationTargetsParse.unset() : this._(true, false, const {});
  const AllocationTargetsParse.malformed(Map<String, double> salvaged)
      : this._(false, true, salvaged);
  const AllocationTargetsParse.ok(Map<String, double> targets)
      : this._(false, false, targets);
}

/// Pure, defensive reader for the C4-A setting shape:
/// `{"v": 1, "targets": {"equity": 65, ...}}`.
///
/// Unknown keys are ignored; values must be finite numbers in 0–100 and the
/// sum of the kept values must be 100 ± 0.05, else the whole read degrades
/// to the malformed/repair state (a hand-crafted curl PUT can store
/// nonsense — the card degrades, nothing crashes).
AllocationTargetsParse parseAllocationTargets(dynamic raw) {
  if (raw == null) return const AllocationTargetsParse.unset();
  if (raw is! Map) return const AllocationTargetsParse.malformed({});
  final t = raw['targets'];
  if (t is! Map) return const AllocationTargetsParse.malformed({});

  final out = <String, double>{};
  var bad = false;
  t.forEach((key, value) {
    if (key is! String || !kAllocationClassKeys.contains(key)) {
      return; // unknown keys ignored (reader tolerance, decision #1)
    }
    if (value is num) {
      final d = value.toDouble();
      if (d.isFinite && d >= 0 && d <= 100) {
        out[key] = d;
      } else {
        bad = true;
      }
    } else {
      bad = true;
    }
  });

  final sum = out.values.fold<double>(0, (a, b) => a + b);
  if (bad || (sum - 100).abs() > 0.05) {
    return AllocationTargetsParse.malformed(out);
  }
  return AllocationTargetsParse.ok(out);
}

/// One "Move $X from A to B" suggestion. Keys are canonical class keys;
/// [amountUsd] is rounded to whole dollars.
class RebalanceMove {
  final String from;
  final String to;
  final double amountUsd;

  const RebalanceMove(this.from, this.to, this.amountUsd);
}

/// Output of [computeRebalanceMoves]: at most `maxLines` moves (largest
/// first), a [truncated] flag when smaller adjustments were elided (either
/// past the line cap or under the $-floor), and [allOnTarget] when every
/// class drift was within the band to begin with.
class RebalanceGuidance {
  final List<RebalanceMove> moves;
  final bool truncated;
  final bool allOnTarget;

  const RebalanceGuidance({
    required this.moves,
    required this.truncated,
    required this.allOnTarget,
  });
}

class _Leg {
  final String key;
  double pp;
  _Leg(this.key, this.pp);
}

/// Greedy surplus→deficit pairing (backlog-4 R3), pure so it is
/// unit-testable without widgets.
///
/// Per-class drift is `actualPct − targetPct` (percentage points, computed
/// over the FULL portfolio total incl. unclassified). Classes within
/// ±[bandPp] never participate. Repeatedly matches the largest remaining
/// surplus with the largest remaining deficit, consuming the smaller side,
/// until every remaining |drift| ≤ [bandPp]. Emitted amounts are rounded to
/// whole dollars; moves under [minMoveUsd] are suppressed and the list is
/// capped at [maxLines] (both set [truncated]). `unclassified` is excluded.
RebalanceGuidance computeRebalanceMoves({
  required Map<String, double> actualPct,
  required Map<String, double> targetPct,
  required double totalUsd,
  double bandPp = kRebalanceBandPp,
  double minMoveUsd = kRebalanceMinMoveUsd,
  int maxLines = kRebalanceMaxMoveLines,
}) {
  final keys = <String>{...actualPct.keys, ...targetPct.keys}
    ..remove('unclassified');

  var allOnTarget = true;
  final surpluses = <_Leg>[];
  final deficits = <_Leg>[];
  for (final key in keys) {
    final drift = (actualPct[key] ?? 0) - (targetPct[key] ?? 0);
    if (drift.abs() <= bandPp) continue;
    allOnTarget = false;
    if (drift > 0) {
      surpluses.add(_Leg(key, drift));
    } else {
      deficits.add(_Leg(key, -drift));
    }
  }

  if (totalUsd <= 0) {
    return RebalanceGuidance(
        moves: const [], truncated: false, allOnTarget: allOnTarget);
  }

  int byPpDesc(_Leg a, _Leg b) {
    final c = b.pp.compareTo(a.pp);
    if (c != 0) return c;
    // Stable tie-break: canonical class ordering.
    return kAllocationClassKeys
        .indexOf(a.key)
        .compareTo(kAllocationClassKeys.indexOf(b.key));
  }

  final raw = <RebalanceMove>[];
  while (true) {
    surpluses.removeWhere((leg) => leg.pp <= bandPp);
    deficits.removeWhere((leg) => leg.pp <= bandPp);
    if (surpluses.isEmpty || deficits.isEmpty) break;
    surpluses.sort(byPpDesc);
    deficits.sort(byPpDesc);
    final s = surpluses.first;
    final d = deficits.first;
    final movedPp = math.min(s.pp, d.pp);
    s.pp -= movedPp;
    d.pp -= movedPp;
    raw.add(RebalanceMove(
        s.key, d.key, (movedPp / 100 * totalUsd).roundToDouble()));
  }

  final kept = raw.where((m) => m.amountUsd >= minMoveUsd).toList();
  final shown = kept.take(maxLines).toList();
  final truncated =
      kept.length > maxLines || (raw.length > kept.length && shown.isNotEmpty);
  return RebalanceGuidance(
      moves: shown, truncated: truncated, allOnTarget: allOnTarget);
}

/// Display label for a canonical asset-class key — must echo the allocation
/// band / filter-chip vocabulary (the shared `pfFilterAsset*` strings), so
/// "equity" reads "Stocks & funds" here exactly as it does one card up.
String rebalanceClassLabel(String key, AppLocalizations l) => switch (key) {
      'equity' => l.pfFilterAssetEquity,
      'bonds' => l.pfFilterAssetBonds,
      'cash' => l.pfFilterAssetCash,
      'crypto' => l.pfFilterAssetCrypto,
      'real_estate' => l.pfFilterAssetRealEstate,
      'commodities' => l.pfFilterAssetCommodities,
      'other' => l.pfFilterAssetOther,
      _ => key,
    };

/// Target allocation & rebalancing card (backlog-4 WS2).
///
/// Sits between the allocation heatmap and the Signals card on the
/// Portfolio tab. Loads per-class target percentages from the generic
/// `app_settings` store (key `allocation_targets`, contract C4-A) and
/// computes drift client-side from the allocation data the dashboard
/// already holds — no backend dependency beyond the existing
/// `getSetting`/`putSetting`.
///
/// States: skeleton (setting loading, reserves the final footprint) →
/// setup CTA (no targets yet, decision #3) / repair (malformed setting,
/// decision #1) / full card (drift rows + move guidance).
class RebalancingCard extends StatefulWidget {
  final ApiService apiService;
  final List<AllocationData> allocationData;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Test seams (widget tests can't subclass ApiService — package:web
  /// breaks the test VM — and must not hit the network). When set they
  /// replace `getSetting('allocation_targets')` / `putSetting(...)`.
  final Future<dynamic> Function()? loadTargetsOverride;
  final Future<void> Function(dynamic value)? saveTargetsOverride;

  const RebalancingCard({
    super.key,
    required this.apiService,
    required this.allocationData,
    required this.conversionFactor,
    required this.currencyFormat,
    this.loadTargetsOverride,
    this.saveTargetsOverride,
  });

  @override
  State<RebalancingCard> createState() => _RebalancingCardState();
}

enum _TargetsStatus { loading, unset, malformed, ready }

class _RebalancingCardState extends State<RebalancingCard> {
  _TargetsStatus _status = _TargetsStatus.loading;
  Map<String, double> _targets = const {};

  /// Valid per-class values salvaged from a malformed setting — the
  /// editor's prefill in the repair state.
  Map<String, double> _salvaged = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    dynamic raw;
    try {
      raw = await (widget.loadTargetsOverride ??
          () => widget.apiService.getSetting('allocation_targets'))();
    } catch (_) {
      // Best-effort read: a failed fetch degrades to the setup CTA
      // rather than an error card (the setting is cheap to re-enter and
      // the save path surfaces its own errors).
      raw = null;
    }
    if (!mounted) return;
    final parsed = parseAllocationTargets(raw);
    setState(() {
      if (parsed.unset) {
        _status = _TargetsStatus.unset;
        _targets = const {};
        _salvaged = const {};
      } else if (parsed.malformed) {
        _status = _TargetsStatus.malformed;
        _targets = const {};
        _salvaged = parsed.targets;
      } else {
        _status = _TargetsStatus.ready;
        _targets = parsed.targets;
        _salvaged = const {};
      }
    });
  }

  /// Aggregate the allocation entries into per-class USD sums + the full
  /// total (incl. unclassified — decision #5 keeps it in the denominator).
  (Map<String, double>, double) _aggregate() {
    final byClass = <String, double>{};
    var total = 0.0;
    for (final item in widget.allocationData) {
      final rawKey = item.assetClassKey;
      final key = (rawKey != null && rawKey.isNotEmpty) ? rawKey : 'other';
      byClass[key] = (byClass[key] ?? 0) + item.value;
      total += item.value;
    }
    return (byClass, total);
  }

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  /// "65" for whole targets, "12.5" otherwise — targets carry at most one
  /// decimal by contract.
  static String _fmtPct(double v) =>
      v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final (actualUsd, totalUsd) = _aggregate();
    // Nothing to reconcile against — an empty allocation renders no card
    // (the heatmap guard upstream makes this near-unreachable).
    if (totalUsd <= 0) return const SizedBox.shrink();

    if (_status == _TargetsStatus.loading) {
      return _buildSkeleton(context, actualUsd, totalUsd);
    }

    final actualPct = <String, double>{
      for (final e in actualUsd.entries) e.key: e.value / totalUsd * 100,
    };

    return switch (_status) {
      _TargetsStatus.unset => _buildCta(context),
      _TargetsStatus.malformed => _buildRepair(context),
      _ => _buildFull(context, actualPct, totalUsd),
    };
  }

  // ---------------------------------------------------------------------
  // Chrome shared by every state — identical to the sibling cards
  // (Card elevation 4, radius 20, 16/24 padding at the 720px breakpoint,
  // MergeSemantics+header title row like the dividend card).
  // ---------------------------------------------------------------------

  double _pad(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

  Widget _card(BuildContext context, List<Widget> children) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(_pad(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _headerRow(BuildContext context, AppLocalizations l,
      {Widget? trailing}) {
    final title = MergeSemantics(
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Icon(Icons.track_changes, color: context.tealAccent, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l.rebCardTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: context.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
    if (trailing == null) return title;
    return Row(
      children: [
        Expanded(child: title),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Loading skeleton — reserves (approximately) the full card's footprint
  // so neighbours don't shift when the setting lands (dividend-card
  // precedent). Row count is estimated from the allocation data already
  // in hand: the classes that would render a drift row.
  // ---------------------------------------------------------------------

  Widget _buildSkeleton(
      BuildContext context, Map<String, double> actualUsd, double totalUsd) {
    final visibleClasses = actualUsd.entries
        .where((e) =>
            e.key != 'unclassified' && e.value / totalUsd * 100 >= 0.5)
        .length;
    final rows = visibleClasses.clamp(3, kAllocationClassKeys.length);
    return _card(context, [
      const SkeletonBox(width: 180, height: 18),
      const SizedBox(height: 16),
      for (var i = 0; i < rows; i++) ...[
        const SkeletonBox(height: 16),
        const SizedBox(height: 6),
        const SkeletonBox(height: 14),
        const SizedBox(height: 14),
      ],
      const SizedBox(height: 2),
      const SkeletonBox(width: 120, height: 12),
      const SizedBox(height: 10),
      const SkeletonBox(height: 13),
      const SizedBox(height: 6),
      const SkeletonBox(height: 13),
      const SizedBox(height: 10),
      const SkeletonBox(width: 260, height: 11),
    ]);
  }

  // ---------------------------------------------------------------------
  // Setup CTA — a new feature must be discoverable, so the card renders
  // compact instead of hiding when no targets are set (decision #3).
  // ---------------------------------------------------------------------

  Widget _buildCta(BuildContext context) {
    final l = AppLocalizations.of(context);
    return _card(context, [
      _headerRow(context, l),
      const SizedBox(height: 10),
      Text(
        l.rebSetTargetsCta,
        style: TextStyle(fontSize: 12.5, color: context.textMuted),
      ),
      const SizedBox(height: 12),
      FilledButton.tonal(
        onPressed: _openEditor,
        child: Text(l.rebSetTargetsButton),
      ),
    ]);
  }

  // ---------------------------------------------------------------------
  // Repair state — the stored setting violates C4-A (e.g. a hand-crafted
  // curl PUT). Never render garbage bars; offer the editor instead.
  // ---------------------------------------------------------------------

  Widget _buildRepair(BuildContext context) {
    final l = AppLocalizations.of(context);
    final color = context.warning;
    return _card(context, [
      _headerRow(context, l),
      const SizedBox(height: 12),
      MergeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child:
                    Icon(Icons.warning_amber_rounded, color: color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l.rebRepairBanner,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.tonal(
        onPressed: _openEditor,
        child: Text(l.rebRepairButton),
      ),
    ]);
  }

  // ---------------------------------------------------------------------
  // Full card — drift rows + guidance.
  // ---------------------------------------------------------------------

  Widget _buildFull(
      BuildContext context, Map<String, double> actualPct, double totalUsd) {
    final l = AppLocalizations.of(context);

    final rows = kAllocationClassKeys
        .where((key) =>
            (_targets[key] ?? 0) > 0 || (actualPct[key] ?? 0) >= 0.5)
        .toList();
    final unclassifiedPct = actualPct['unclassified'] ?? 0;

    final guidance = computeRebalanceMoves(
      actualPct: actualPct,
      targetPct: _targets,
      totalUsd: totalUsd,
    );

    return _card(context, [
      _headerRow(
        context,
        l,
        trailing: TextButton(
          onPressed: _openEditor,
          child: Text(l.rebEditTargets),
        ),
      ),
      const SizedBox(height: 12),
      for (final key in rows)
        _driftRow(context, l, key, actualPct[key] ?? 0, _targets[key] ?? 0),
      if (unclassifiedPct >= 0.05)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(Icons.help_outline,
                      size: 13, color: context.textFaint),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.rebUnclassifiedFootnote(
                        unclassifiedPct.toStringAsFixed(1)),
                    style:
                        TextStyle(fontSize: 11.5, color: context.textFaint),
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 4),
      Divider(height: 24, color: context.hairline),
      Semantics(
        header: true,
        child: Text(
          l.rebGuidanceTitle,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: context.textSubtle,
          ),
        ),
      ),
      const SizedBox(height: 8),
      if (guidance.moves.isEmpty)
        MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  guidance.allOnTarget
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  size: 15,
                  color: guidance.allOnTarget
                      ? context.positive
                      : context.textMuted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  guidance.allOnTarget ? l.rebNoMoves : l.rebBelowFloor,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: guidance.allOnTarget
                        ? context.positive
                        : context.textMuted,
                  ),
                ),
              ),
            ],
          ),
        )
      else ...[
        for (final move in guidance.moves)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1.5),
                      child: Icon(Icons.swap_horiz,
                          size: 14, color: context.textMuted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.rebMoveLine(
                        _money(move.amountUsd),
                        rebalanceClassLabel(move.from, l),
                        rebalanceClassLabel(move.to, l),
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: context.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (guidance.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 22),
            child: Text(
              l.rebMoreAdjustments,
              style: TextStyle(fontSize: 11.5, color: context.textFaint),
            ),
          ),
      ],
      const SizedBox(height: 10),
      // Mandatory: the owner's concentrated position makes naive sell
      // advice tax-expensive — the guidance must always carry this caveat.
      Text(
        l.rebTaxCaption,
        style: TextStyle(
          fontSize: 11,
          color: context.textFaint,
          fontStyle: FontStyle.italic,
        ),
      ),
    ]);
  }

  /// One class row: label + actual/target figures + delta chip, over a
  /// drift bar (fill = actual %, 2px tick at target %). Fill turns from
  /// positive to warning past the ±2pp band.
  Widget _driftRow(BuildContext context, AppLocalizations l, String key,
      double actualPct, double targetPct) {
    final delta = actualPct - targetPct;
    final within = delta.abs() <= kRebalanceBandPp;
    final accent = within ? context.positive : context.warning;
    final deltaStr =
        '${delta >= 0 ? '+' : '-'}${delta.abs().toStringAsFixed(1)}';
    final chipText = within ? l.rebOnTargetChip : l.rebDeltaChip(deltaStr);
    final actualStr = actualPct.toStringAsFixed(1);
    final targetStr = _fmtPct(targetPct);
    final label = rebalanceClassLabel(key, l);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: MergeSemantics(
        child: Semantics(
          label: l.rebRowSemantics(label, actualStr, targetStr, chipText),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$actualStr% / $targetStr%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: accent.withValues(alpha: 0.35)),
                      ),
                      child: Text(
                        chipText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 14,
                  child: LayoutBuilder(builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    final fillW = w * (actualPct / 100).clamp(0.0, 1.0);
                    final tickLeft =
                        ((w - 2) * (targetPct / 100)).clamp(0.0, w - 2);
                    return Stack(children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 3,
                        child: Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: ctx.hairline,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 3,
                        child: Container(
                          width: fillW,
                          height: 8,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      // Target tick: full-height 2px mark in the primary
                      // text colour, readable over both the empty track
                      // and the positive/warning fill in either theme.
                      Positioned(
                        left: tickLeft,
                        top: 0,
                        child: Container(
                          width: 2,
                          height: 14,
                          decoration: BoxDecoration(
                            color:
                                ctx.textPrimary.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ]);
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Editor + persistence.
  // ---------------------------------------------------------------------

  Future<void> _openEditor() async {
    final (actualUsd, totalUsd) = _aggregate();
    // Prefill priority: current targets → values salvaged from a malformed
    // setting → current actuals rounded to integers (best-guess starting
    // point, normalized to 100 via the "Distribute remainder" helper).
    Map<String, double> prefill;
    if (_status == _TargetsStatus.ready) {
      prefill = _targets;
    } else if (_salvaged.isNotEmpty) {
      prefill = _salvaged;
    } else if (totalUsd > 0) {
      prefill = {
        for (final e in actualUsd.entries)
          if (e.key != 'unclassified')
            e.key: (e.value / totalUsd * 100).roundToDouble(),
      };
    } else {
      prefill = const {};
    }
    final hasExisting = _status == _TargetsStatus.ready ||
        _status == _TargetsStatus.malformed;

    final outcome = await showModalBottomSheet<_EditorOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _TargetsEditorSheet(
        initial: prefill,
        hasExisting: hasExisting,
      ),
    );
    if (outcome == null || !mounted) return;
    if (outcome.remove) {
      await _removeTargets();
    } else if (outcome.targets != null) {
      await _saveTargets(outcome.targets!);
    }
  }

  Future<void> _putSetting(dynamic value) =>
      (widget.saveTargetsOverride ??
          (v) => widget.apiService.putSetting('allocation_targets', v))(value);

  /// Optimistic save: the card flips to the new targets immediately; a
  /// failed PUT reverts and surfaces a snackbar.
  Future<void> _saveTargets(Map<String, double> targets) async {
    final prevStatus = _status;
    final prevTargets = _targets;
    final prevSalvaged = _salvaged;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorText = AppLocalizations.of(context).rebSaveError;

    setState(() {
      _status = _TargetsStatus.ready;
      _targets = targets;
      _salvaged = const {};
    });

    // C4-A write shape; whole numbers stored as ints for a clean JSON.
    final payload = {
      'v': 1,
      'targets': {
        for (final e in targets.entries)
          if (e.value > 0)
            e.key: e.value % 1 == 0 ? e.value.toInt() : e.value,
      },
    };
    try {
      await _putSetting(payload);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = prevStatus;
        _targets = prevTargets;
        _salvaged = prevSalvaged;
      });
      messenger?.showSnackBar(SnackBar(content: Text(errorText)));
    }
  }

  /// Cleared state is JSON `null` (contract C4-A) — the same value the
  /// GET returns for never-written, so one read path handles both.
  Future<void> _removeTargets() async {
    final prevStatus = _status;
    final prevTargets = _targets;
    final prevSalvaged = _salvaged;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorText = AppLocalizations.of(context).rebRemoveError;

    setState(() {
      _status = _TargetsStatus.unset;
      _targets = const {};
      _salvaged = const {};
    });
    try {
      await _putSetting(null);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = prevStatus;
        _targets = prevTargets;
        _salvaged = prevSalvaged;
      });
      messenger?.showSnackBar(SnackBar(content: Text(errorText)));
    }
  }
}

class _EditorOutcome {
  final bool remove;
  final Map<String, double>? targets;

  const _EditorOutcome.save(Map<String, double> this.targets)
      : remove = false;
  const _EditorOutcome.remove()
      : remove = true,
        targets = null;
}

/// Rejects any edit that isn't `up to 3 digits, optionally a dot and one
/// decimal` — keeps the field parseable at every keystroke (range is
/// enforced by the Save validation, not here).
class _PercentInputFormatter extends TextInputFormatter {
  static final _re = RegExp(r'^\d{0,3}(\.\d?)?$');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return _re.hasMatch(newValue.text) ? newValue : oldValue;
  }
}

/// Bottom-sheet targets editor (backlog-4 R2): seven percentage fields in
/// canonical order, a live sum-to-100 meter, a "Distribute remainder"
/// helper, and (when a setting exists) a confirmed "Remove targets"
/// destructive action.
class _TargetsEditorSheet extends StatefulWidget {
  final Map<String, double> initial;
  final bool hasExisting;

  const _TargetsEditorSheet({
    required this.initial,
    required this.hasExisting,
  });

  @override
  State<_TargetsEditorSheet> createState() => _TargetsEditorSheetState();
}

class _TargetsEditorSheetState extends State<_TargetsEditorSheet> {
  late final Map<String, TextEditingController> _controllers = {
    for (final key in kAllocationClassKeys)
      key: TextEditingController(
        text: (widget.initial[key] ?? 0) > 0
            ? _fmt(widget.initial[key]!)
            : '',
      ),
  };

  @override
  void initState() {
    super.initState();
    for (final c in _controllers.values) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _fmt(double v) =>
      v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  double _valueOf(String key) {
    final text = _controllers[key]!.text.trim();
    if (text.isEmpty) return 0;
    return double.tryParse(text) ?? double.nan;
  }

  double get _total {
    var sum = 0.0;
    for (final key in kAllocationClassKeys) {
      final v = _valueOf(key);
      if (v.isNaN) return double.nan;
      sum += v;
    }
    return sum;
  }

  bool get _inRange => kAllocationClassKeys.every((key) {
        final v = _valueOf(key);
        return !v.isNaN && v >= 0 && v <= 100;
      });

  bool get _valid => _inRange && (_total - 100).abs() <= 0.05;

  /// Dumps the residual to 100 into the largest field (clamped 0–100,
  /// one decimal) — the one-tap way to normalize an actuals-based prefill.
  void _distribute() {
    final total = _total;
    if (total.isNaN) return;
    final residual = 100 - total;
    if (residual.abs() < 0.05) return;
    var bestKey = kAllocationClassKeys.first;
    var bestVal = _valueOf(bestKey);
    for (final key in kAllocationClassKeys.skip(1)) {
      final v = _valueOf(key);
      if (v > bestVal) {
        bestVal = v;
        bestKey = key;
      }
    }
    final next =
        (((bestVal + residual) * 10).roundToDouble() / 10).clamp(0.0, 100.0);
    _controllers[bestKey]!.text = next > 0 ? _fmt(next) : '';
  }

  void _save() {
    final targets = <String, double>{
      for (final key in kAllocationClassKeys)
        if (_valueOf(key) > 0) key: _valueOf(key),
    };
    Navigator.of(context).pop(_EditorOutcome.save(targets));
  }

  Future<void> _confirmRemove() async {
    final l = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l.rebRemoveConfirmTitle),
        content: Text(l.rebRemoveConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: dialogCtx.negative,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l.rebRemoveTargets),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      navigator.pop(const _EditorOutcome.remove());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final total = _total;
    final totalStr = total.isNaN
        ? '—'
        : (total % 1 == 0 ? total.toInt().toString() : total.toStringAsFixed(1));
    final residualActive = !total.isNaN && (100 - total).abs() >= 0.05;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  l.rebEditorTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              for (final key in kAllocationClassKeys)
                SizedBox(
                  // 44px+ touch target per row (a11y).
                  height: 48,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          rebalanceClassLabel(key, l),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 96,
                        child: TextField(
                          controller: _controllers[key],
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textAlign: TextAlign.right,
                          inputFormatters: [_PercentInputFormatter()],
                          style: const TextStyle(
                            fontSize: 14,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                          decoration: const InputDecoration(
                            suffixText: '%',
                            isDense: true,
                            hintText: '0',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.rebEditorTotal(totalStr),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _valid ? context.positive : context.warning,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: residualActive ? _distribute : null,
                    child: Text(l.rebDistributeRemainder),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l.actionCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _valid ? _save : null,
                    child: Text(l.actionSave),
                  ),
                ],
              ),
              if (widget.hasExisting)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: context.negative),
                    onPressed: _confirmRemove,
                    child: Text(l.rebRemoveTargets),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
