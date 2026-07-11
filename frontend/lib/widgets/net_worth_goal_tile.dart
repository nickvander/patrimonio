import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/preferences.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// Compact "where am I against my net-worth goal" tile shown on the
/// Overview tab. Reads the same goal that drives the projections chart
/// overlay, so editing it in either place updates both.
class NetWorthGoalTile extends StatelessWidget {
  /// Net worth in USD (the storage unit) — display multiplies through
  /// the conversion factor.
  final double netWorthUsd;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Net-worth snapshots (each a `{date, net_worth}` map, net_worth in USD),
  /// oldest-first. Used to derive a growth velocity and project whether the
  /// goal is on pace. Empty/insufficient history simply omits the pace label.
  final List<dynamic> history;

  const NetWorthGoalTile({
    super.key,
    required this.netWorthUsd,
    required this.conversionFactor,
    required this.currencyFormat,
    this.history = const [],
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Tighter card interior on phones — 24px each side eats ~16% of a 360px
    // screen's width.
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    final goalUsd = Preferences.getGoalAmountUsd();
    final goalYear = Preferences.getGoalYear();
    if (goalUsd == null || goalYear == null || goalUsd <= 0) {
      return const SizedBox.shrink();
    }

    final pace = _computePace(goalUsd, goalYear);

    final pct = (netWorthUsd / goalUsd).clamp(0.0, 1.0);
    final pctLabel = (pct * 100).toStringAsFixed(1);
    final yearsRemaining = goalYear - DateTime.now().year;
    // Brightness-aware so the goal accent is AA-readable on both
    // surfaces — neon emerald/teal/yellow only pass on dark cards.
    final color = pct >= 1.0
        ? context.positive
        : pct >= 0.5
            ? context.tealAccent
            : context.yellowAccent;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag_outlined, color: color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.pfNetWorthGoal,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$pctLabel%',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              // gen-l10n orders these alphabetically → (amount, remaining, year).
              l.pfGoalHitBy(
                currencyFormat.displayMoney(goalUsd * conversionFactor),
                yearsRemaining <= 0
                    ? l.pfGoalDueNow
                    : l.pfGoalYearsLeft(yearsRemaining),
                goalYear,
              ),
              style: TextStyle(color: context.textMuted, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: context.tileSurface,
                color: color,
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l.pfGoalCurrent(
                  currencyFormat.displayMoney(netWorthUsd * conversionFactor)),
              style: TextStyle(
                fontSize: 12,
                color: context.textSubtle,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (pace != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(pace.icon, size: 14, color: pace.color(context)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pace.label(l, currencyFormat, conversionFactor),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: pace.color(context),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Derive a pace verdict (ahead / on track / behind) from the growth
  /// velocity in [history]. Returns null when there isn't enough history to
  /// project honestly — at least two points spanning a meaningful window —
  /// so the tile never shows a misleading verdict from a single snapshot.
  _PaceVerdict? _computePace(double goalUsd, int goalYear) {
    final points = history.whereType<Map>().where((p) {
      return DateTime.tryParse((p['date'] ?? '').toString()) != null &&
          (p['net_worth'] as num?) != null;
    }).toList();
    if (points.length < 2) return null;

    // Anchor on the point closest to ~12 months before the latest, so the
    // velocity is an annualized-then-monthly average rather than noise from
    // the most recent snapshot pair. Fall back to the oldest point when the
    // history is shorter than a year.
    final latest = points.last;
    final latestDate = DateTime.parse((latest['date']).toString());
    final latestNet = (latest['net_worth'] as num).toDouble();
    final target = DateTime(latestDate.year - 1, latestDate.month, latestDate.day);

    Map anchor = points.first;
    var bestDist = (DateTime.parse((points.first['date']).toString())
            .difference(target)
            .inDays)
        .abs();
    for (final p in points) {
      final d = DateTime.parse((p['date']).toString());
      if (!d.isBefore(latestDate)) continue;
      final dist = d.difference(target).inDays.abs();
      if (dist < bestDist) {
        bestDist = dist;
        anchor = p;
      }
    }
    final anchorDate = DateTime.parse((anchor['date']).toString());
    final anchorNet = (anchor['net_worth'] as num).toDouble();

    final monthsSpan = latestDate.difference(anchorDate).inDays / 30.4375;
    // Need a real window (≈1 month+) to compute a monthly velocity; anything
    // shorter is too noisy to project a multi-year goal from.
    if (monthsSpan < 1.0) return null;

    final monthlyDelta = (latestNet - anchorNet) / monthsSpan;

    // The catch-up contribution that would still land the goal in [goalYear]:
    // spread the remaining gap over the months left until the target year-end.
    // Surfaced when behind so the tile says *how much more* per month it takes.
    final monthsRemaining = _monthsUntilGoalYearEnd(goalYear);
    final requiredMonthly = (monthsRemaining > 0 && latestNet < goalUsd)
        ? (goalUsd - latestNet) / monthsRemaining
        : null;

    // A flat-or-shrinking trajectory can never reach a goal above today's
    // net worth — flag it as behind with a warning, no bogus projection date,
    // but still surface the catch-up contribution it would take.
    if (monthlyDelta <= 0) {
      return latestNet >= goalUsd
          ? const _PaceVerdict.ahead()
          : _PaceVerdict.behind(warning: true, requiredMonthlyUsd: requiredMonthly);
    }

    if (latestNet >= goalUsd) return const _PaceVerdict.ahead();

    final monthsToGoal = (goalUsd - latestNet) / monthlyDelta;
    final projected = DateTime(
      latestDate.year,
      latestDate.month + monthsToGoal.ceil(),
    );
    final projectedYear = projected.year;

    if (projectedYear < goalYear) {
      return _PaceVerdict.ahead(
          projected: projected, monthlyDeltaUsd: monthlyDelta);
    }
    if (projectedYear > goalYear) {
      return _PaceVerdict.behind(requiredMonthlyUsd: requiredMonthly);
    }
    return _PaceVerdict.onTrack(
        projected: projected, monthlyDeltaUsd: monthlyDelta);
  }

  /// Whole months from now until the end of [goalYear] (December). Zero once
  /// the goal year is already in the past, so callers skip the catch-up math.
  int _monthsUntilGoalYearEnd(int goalYear) {
    final now = DateTime.now();
    final months = (goalYear - now.year) * 12 + (12 - now.month);
    return months < 0 ? 0 : months;
  }
}

/// A goal-pace verdict: whether the current net-worth velocity puts the
/// goal ahead of, on, or behind its target year. [warning] flags the
/// special "net worth is flat/shrinking" case so the tile can colour it.
///
/// When velocity is positive, [projected]/[monthlyDeltaUsd] carry the
/// projected completion date and the monthly pace so the label can read
/// "on pace for ~<month year> at +$X/mo". When behind, [requiredMonthlyUsd]
/// carries the catch-up contribution needed to still hit the goal year. All
/// USD amounts are storage units — the label multiplies through the
/// display conversion factor.
class _PaceVerdict {
  final int _kind; // 0 = ahead, 1 = onTrack, 2 = behind
  final bool warning;

  /// Projected completion date (positive velocity only); null otherwise.
  final DateTime? projected;

  /// Monthly net-worth velocity in USD (positive velocity only).
  final double? monthlyDeltaUsd;

  /// Catch-up contribution per month in USD to still land the goal year
  /// (behind only); null when it can't be computed (goal year past, etc.).
  final double? requiredMonthlyUsd;

  const _PaceVerdict.ahead({this.projected, this.monthlyDeltaUsd})
      : _kind = 0,
        warning = false,
        requiredMonthlyUsd = null;
  const _PaceVerdict.onTrack({this.projected, this.monthlyDeltaUsd})
      : _kind = 1,
        warning = false,
        requiredMonthlyUsd = null;
  const _PaceVerdict.behind({this.warning = false, this.requiredMonthlyUsd})
      : _kind = 2,
        projected = null,
        monthlyDeltaUsd = null;

  IconData get icon => _kind == 0
      ? Icons.trending_up_rounded
      : _kind == 1
          ? Icons.check_circle_outline_rounded
          : Icons.trending_down_rounded;

  Color color(BuildContext context) {
    if (warning) return context.warning;
    return _kind == 0
        ? context.positive
        : _kind == 1
            ? context.tealAccent
            : context.warning;
  }

  String label(
    AppLocalizations l,
    NumberFormat currencyFormat,
    double conversionFactor,
  ) {
    final base = _kind == 0
        ? l.pfGoalPaceAhead
        : _kind == 1
            ? l.pfGoalPaceOnTrack
            : l.pfGoalPaceBehind;

    // On-pace projection: "<verdict> · on pace for ~<month year> at +$X/mo".
    if (projected != null &&
        monthlyDeltaUsd != null &&
        monthlyDeltaUsd! > 0) {
      // yMMM follows the locale ("Jun 2028" / "jun 2028").
      final when = DateFormat.yMMM().format(projected!);
      final rate =
          currencyFormat.displayMoney(monthlyDeltaUsd! * conversionFactor);
      // gen-l10n orders positional args alphabetically: (rate, when).
      return '$base · ${l.pfGoalOnPaceFor(rate, when)}';
    }

    // Behind: surface the catch-up contribution to still hit the goal year.
    if (_kind == 2 && requiredMonthlyUsd != null && requiredMonthlyUsd! > 0) {
      final need =
          currencyFormat.displayMoney(requiredMonthlyUsd! * conversionFactor);
      return '$base · ${l.pfGoalNeedPerMonth(need)}';
    }

    return base;
  }
}
