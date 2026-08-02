import 'dart:math' as math;

import 'spending_insight.dart';

/// The claim a drill-down carries to its destination.
///
/// Principle: every bell/card drill-down must CARRY ITS CLAIM to the
/// landing surface and reconcile it against the evidence shown there. The
/// claim is DISPLAY state, not a one-shot seed: the host (dashboard /
/// account panel) owns it and clears it on user dismiss or replacement by
/// a newer jump, while the destination gates the banner's visibility on
/// the jump's seeded filter still being active — removing the seeded chip
/// or "Clear all" hides it with zero extra state to reconcile.
sealed class DrillDownClaim {
  const DrillDownClaim();
}

/// Spending-spike drill-down claim ("Groceries in Mar 2026: $612.00 spent
/// — 45% above your 6-month average of $408.00"). Wraps the insight the
/// user drilled down from so the banner renders the SAME figures the bell
/// row alerted on. Gated on the seeded category filter still active.
class SpikeClaim extends DrillDownClaim {
  final SpendingSpikeInsight insight;

  const SpikeClaim(this.insight);
}

/// Count claim from a since-visit digest row ("15 new since Jul 31").
///
/// Count claims carry NO reconciliation line: the visible list count is
/// the same measurement the claim restates, so a second number would be
/// redundant at best and contradictory at worst.
class NewSinceCountClaim extends DrillDownClaim {
  /// The count the digest row claimed.
  final int count;

  /// The RAW previous-visit anchor instant — the same value seeded into
  /// `TxFilters.createdSince`, which is also the banner's visibility gate.
  final DateTime anchor;

  const NewSinceCountClaim({required this.count, required this.anchor});
}

/// Balance-move claim ("Net worth +$X (+Y%) since Jul 30" / "Cards · SoFi
/// moved +$X since Jul 31").
///
/// Balance claims get the reconciliation line: synced transactions are
/// only PART of the evidence for a balance delta (transfers, pending
/// charges and valuation moves change balances without producing synced
/// rows), so the banner must say how much of the move the visible rows
/// actually account for — and never fabricate rows to close the gap.
class BalanceMoveClaim extends DrillDownClaim {
  /// Signed delta, USD-stored — the same payload figure the bell row
  /// formatted. Converted at render through the host's conversion factor
  /// (identical to the spike banner's money handling).
  final double deltaUsd;

  /// Signed percentage NUMBER (+3.6 == +3.6%), or null when the source
  /// has no meaningful baseline (the largest-move payload).
  final double? pct;

  /// The since-anchor of the move — the same instant seeded into
  /// `TxFilters.createdSince`, which is also the banner's visibility gate.
  final DateTime anchor;

  /// Display name of the moved account; null = a whole-net-worth claim.
  final String? accountName;

  const BalanceMoveClaim({
    required this.deltaUsd,
    this.pct,
    required this.anchor,
    this.accountName,
  });
}

/// Whether a balance claim's reconciliation line should render: only when
/// the visible rows' net sum genuinely fails to explain the claimed move —
/// |claim − shownSum| > max($1, 5% of |claim|) — with both figures in the
/// reporting currency (the caller converts them with the same machinery
/// as the filtered summary line). Below the threshold the line would only
/// restate FX/rounding noise as a discrepancy.
bool balanceClaimHasGap({
  required double claimAmount,
  required double shownSum,
}) => (claimAmount - shownSum).abs() > math.max(1.0, 0.05 * claimAmount.abs());
