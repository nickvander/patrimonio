import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/theme_colors.dart';
import '../utils/account_category.dart';
import '../utils/category.dart';
import '../l10n/app_localizations.dart';

/// One notification row shown in the bell-icon popover.
class AppNotification {
  /// Stable identity for read-state tracking — keyed on the type + the
  /// entity it concerns (and, where a recurrence should re-alert, a
  /// date/value bucket). Two derivations of the same underlying condition
  /// produce the same id, so "mark as read" sticks across refreshes.
  final String id;
  final IconData icon;
  final Color accent;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  AppNotification({
    required this.id,
    required this.icon,
    required this.accent,
    required this.title,
    required this.detail,
    this.onTap,
  });
}

/// Pure derivation: walks the existing sync data + net-worth history and
/// emits notification rows for the conditions the user cares about. Lives
/// in widget code rather than the API because all the inputs are already
/// in memory client-side.
List<AppNotification> deriveNotifications({
  required AppLocalizations l,
  required List<dynamic> syncData,
  required List<dynamic> netWorthHistory,
  required VoidCallback onJumpToManagement,
  /// Upcoming + overdue loan installments from GET /api/loans/reminders.
  /// Empty when lending is off (the endpoint returns []). Each item:
  /// {borrower_name, amount, currency, due_date, installment_number,
  /// days_until, days_overdue}.
  List<dynamic> loanReminders = const [],
  /// Jump to the Lending tab when a loan reminder is tapped.
  VoidCallback? onJumpToLending,
  /// All accounts (from the dashboard overview) for low-balance alerts.
  List<dynamic> accounts = const [],
  /// account_id -> low-balance threshold in that account's native currency.
  Map<String, double> accountAlerts = const {},
  /// Opens an account's detail panel when its low-balance row is tapped.
  void Function(Map<String, dynamic> account)? onJumpToAccount,
  /// Per-category spend deltas from GET /api/dashboard/spending-insights:
  /// {recent_month, lookback, categories:[{user_category, category_detailed,
  /// category, recent, previous_avg, trailing_avg}]}. Null/absent when the
  /// fetch failed — the spending-up rows simply don't appear.
  Map<String, dynamic>? spendingInsights,
  /// Detected recurring outflows from GET /api/dashboard/subscriptions, used
  /// to surface a subscription whose price went up (a higher-priced cluster
  /// supersedes a same-merchant lower-priced one).
  List<dynamic> subscriptions = const [],
  /// Jump to the Cash-flow tab when a spending-insight / subscription row is
  /// tapped.
  VoidCallback? onJumpToSpending,
}) {
  final out = <AppNotification>[];

  // 0) Loan reminders — overdue first (red), then upcoming (amber).
  //    The server sends exactly one of days_overdue / days_until > 0
  //    per row, so each installment yields at most one notification.
  String money(num v, String cur) => NumberFormat.currency(
        symbol: cur == 'MXN' ? 'MXN ' : r'$',
        decimalDigits: 2,
      ).format(v);
  for (final raw in loanReminders) {
    if (raw is! Map) continue;
    final borrower = (raw['borrower_name'] ?? l.lwNotifBorrowerFallback).toString();
    final amount = (raw['amount'] as num?)?.toDouble() ?? 0;
    final cur = (raw['currency'] ?? 'USD').toString();
    final n = (raw['installment_number'] as num?)?.toInt() ?? 0;
    final overdue = (raw['days_overdue'] as num?)?.toInt() ?? 0;
    final until = (raw['days_until'] as num?)?.toInt() ?? 0;
    final due = DateTime.tryParse(raw['due_date']?.toString() ?? '');
    final dueStr = due != null ? DateFormat('MMM d').format(due) : '';
    if (overdue > 0) {
      out.add(AppNotification(
        id: 'loan_overdue:$borrower:$n',
        icon: Icons.event_busy,
        accent: Colors.redAccent,
        title: l.lwNotifRepaymentOverdueTitle(borrower),
        detail: l.lwNotifRepaymentOverdueDetail(
            n, money(amount, cur), dueStr, overdue),
        onTap: onJumpToLending,
      ));
    } else if (until > 0) {
      out.add(AppNotification(
        id: 'loan_due:$borrower:$n',
        icon: Icons.event,
        accent: Colors.amber,
        title: l.lwNotifRepaymentDueTitle(borrower, until),
        detail: l.lwNotifRepaymentDueDetail(n, money(amount, cur), dueStr),
        onTap: onJumpToLending,
      ));
    } else {
      // Due today: days_until and days_overdue are both 0 (the backend only
      // returns reminders within the lead window, so both-zero means today).
      // Without this branch a loan due today produced a reminder row but no
      // notification at all — exactly on the day it matters most.
      out.add(AppNotification(
        id: 'loan_due_today:$borrower:$n',
        icon: Icons.event_available,
        accent: Colors.amber,
        title: l.lwNotifRepaymentDueTodayTitle(borrower),
        detail: l.lwNotifRepaymentDueTodayDetail(n, money(amount, cur)),
        onTap: onJumpToLending,
      ));
    }
  }

  // 0b) Low-balance alerts — accounts whose balance has fallen to or below
  //     the user's per-account threshold. Credit/loan accounts are skipped
  //     (a low balance there is good news, not a warning).
  if (accountAlerts.isNotEmpty) {
    for (final raw in accounts) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString();
      if (id == null) continue;
      final threshold = accountAlerts[id];
      if (threshold == null) continue;
      final cat = categorizeAccount(raw['account_type']?.toString());
      if (cat == AccountCategory.credit || cat == AccountCategory.loan) {
        continue;
      }
      final bal = (raw['current_balance'] as num?)?.toDouble() ?? 0.0;
      if (bal > threshold) continue;
      final name = (raw['nickname']?.toString().trim().isNotEmpty ?? false)
          ? raw['nickname'].toString()
          : (raw['name'] ?? l.lwNotifAccountFallback).toString();
      final cur = (raw['currency'] ?? 'USD').toString();
      out.add(AppNotification(
        id: 'low_balance:$id',
        icon: Icons.account_balance_wallet_outlined,
        accent: Colors.amber,
        title: l.lwNotifLowBalanceTitle(name),
        detail: l.lwNotifLowBalanceDetail(money(bal, cur), money(threshold, cur)),
        onTap: onJumpToAccount == null
            ? null
            : () => onJumpToAccount(Map<String, dynamic>.from(raw)),
      ));
    }
  }

  // 1) Sync issues — anything not "synced" or "manual" earns a row.
  for (final raw in syncData) {
    if (raw is! Map) continue;
    final status = raw['sync_status']?.toString();
    final name = (raw['name'] ?? l.lwNotifInstitutionFallback).toString();
    if (status == 'reconnect_required') {
      out.add(AppNotification(
        id: 'sync_reconnect:$name',
        icon: Icons.link_off,
        accent: Colors.orangeAccent,
        title: l.lwNotifNeedsReconnectTitle(name),
        detail: l.lwNotifNeedsReconnectDetail,
        onTap: onJumpToManagement,
      ));
    } else if (status == 'error' || status == 'failed') {
      out.add(AppNotification(
        id: 'sync_failed:$name',
        icon: Icons.error_outline,
        accent: Colors.redAccent,
        title: l.lwNotifSyncFailedTitle(name),
        detail: (raw['last_sync_error'] ?? l.lwNotifUnknownSyncError).toString(),
        onTap: onJumpToManagement,
      ));
    } else if (status == 'synced') {
      // Stale sync — over a week since last successful run.
      final raw2 = raw['last_synced_at']?.toString();
      if (raw2 != null) {
        final dt = DateTime.tryParse(raw2);
        if (dt != null) {
          final days = DateTime.now().difference(dt).inDays;
          if (days >= 7) {
            out.add(AppNotification(
              id: 'sync_stale:$name',
              icon: Icons.access_time,
              accent: Colors.amber,
              title: l.lwNotifStaleSyncTitle(name, days),
              detail: l.lwNotifStaleSyncDetail,
              onTap: onJumpToManagement,
            ));
          }
        }
      }
    }
  }

  // 2) Net-worth drop — 30-day delta below -5% gets surfaced.
  if (netWorthHistory.length >= 2) {
    final sorted = [...netWorthHistory];
    sorted.sort((a, b) {
      final ad = DateTime.tryParse(a['date']?.toString() ?? '') ??
          DateTime(2000);
      final bd = DateTime.tryParse(b['date']?.toString() ?? '') ??
          DateTime(2000);
      return ad.compareTo(bd);
    });
    final latest = sorted.last;
    final latestNw = (latest['net_worth'] as num?)?.toDouble() ?? 0.0;
    final latestDt =
        DateTime.tryParse(latest['date']?.toString() ?? '') ?? DateTime.now();
    final target = latestDt.subtract(const Duration(days: 30));
    Map<String, dynamic>? ref;
    for (final p in sorted.reversed) {
      final d = DateTime.tryParse(p['date']?.toString() ?? '');
      if (d == null) continue;
      if (d.isBefore(target) || d.isAtSameMomentAs(target)) {
        ref = p as Map<String, dynamic>;
        break;
      }
    }
    if (ref != null) {
      final refNw = (ref['net_worth'] as num?)?.toDouble() ?? 0.0;
      if (refNw > 0) {
        final pct = ((latestNw - refNw) / refNw) * 100;
        if (pct <= -5) {
          out.add(AppNotification(
            id: 'net_worth_drop:${DateFormat('yyyy-MM-dd').format(latestDt)}',
            icon: Icons.trending_down,
            accent: Colors.redAccent,
            title: l.lwNotifNetWorthDropTitle('${pct.toStringAsFixed(1)}%'),
            detail: l.lwNotifNetWorthDropDetail(
              DateFormat('MMM d').format(latestDt),
              DateFormat('MMM d').format(
                  DateTime.tryParse(ref['date']?.toString() ?? '') ??
                      latestDt),
            ),
          ));
        }
      }
    }
  }

  // 3) Spending spikes — a category whose most-recent complete month ran
  //    meaningfully above its trailing average. Amounts are USD-normalised by
  //    the backend (same as the cash-flow card). Thresholds keep the signal
  //    actionable: a baseline of at least $50 (so a $2→$6 coffee doesn't
  //    scream), a ≥25% jump, and at most the three biggest increases.
  final lookback = (spendingInsights?['lookback'] as num?)?.toInt() ?? 3;
  final recentMonth = (spendingInsights?['recent_month'] ?? '').toString();
  final insightCats = spendingInsights?['categories'];
  if (insightCats is List) {
    const minBaseline = 50.0;
    const minJump = 0.25;
    // Raw category codes that aren't worth nagging about — they have no
    // single actionable merchant/behaviour behind them.
    const skip = {'UNCATEGORIZED', 'OTHER', 'OTHER_OTHER'};
    final spikes = <({String code, String label, double pct, double avg})>[];
    for (final raw in insightCats) {
      if (raw is! Map) continue;
      final recent = (raw['recent'] as num?)?.toDouble() ?? 0.0;
      final prev = (raw['previous_avg'] as num?)?.toDouble() ?? 0.0;
      if (prev < minBaseline || recent <= prev) continue;
      final pct = (recent - prev) / prev;
      if (pct < minJump) continue;
      final code = (raw['user_category'] ?? raw['category_detailed'] ?? raw['category'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      if (skip.contains(code)) continue;
      final label = prettyCategory(
        userCategory: raw['user_category']?.toString(),
        detailed: raw['category_detailed']?.toString(),
        primary: raw['category']?.toString(),
      );
      spikes.add((code: code, label: label, pct: pct, avg: prev));
    }
    // Biggest absolute increase first; cap at three so the bell stays calm.
    spikes.sort((a, b) => (b.pct * b.avg).compareTo(a.pct * a.avg));
    for (final s in spikes.take(3)) {
      out.add(AppNotification(
        id: 'spending_up:${s.code}:$recentMonth',
        icon: Icons.trending_up,
        accent: Colors.orangeAccent,
        title: l.lwNotifSpendingUpTitle(
            s.label, '${(s.pct * 100).round()}%'),
        detail: l.lwNotifSpendingUpDetail(lookback, money(s.avg, 'USD')),
        onTap: onJumpToSpending,
      ));
    }
  }

  // 4) Subscription price increase — the detector clusters recurring charges
  //    by (merchant, rounded amount), so a price change splits one merchant
  //    into two clusters. When an active (current) cluster's last charge is
  //    both newer and pricier than an earlier same-merchant cluster, that's a
  //    price hike. Compare within a single currency; require a ≥8% / ≥$1 jump.
  if (subscriptions.isNotEmpty) {
    // merchant key -> list of its clusters.
    final byMerchant = <String, List<Map>>{};
    for (final raw in subscriptions) {
      if (raw is! Map) continue;
      final m = (raw['merchant'] ?? '').toString().trim();
      if (m.isEmpty) continue;
      byMerchant.putIfAbsent(m.toLowerCase(), () => []).add(raw);
    }
    final hikes = <({String merchant, double now, double was, String cur})>[];
    byMerchant.forEach((_, clusters) {
      if (clusters.length < 2) return;
      // Current = the active cluster with the most recent last charge.
      Map? current;
      for (final c in clusters) {
        if (c['status'] != 'active') continue;
        if (current == null ||
            (c['last_charge_date'] ?? '').toString().compareTo(
                    (current['last_charge_date'] ?? '').toString()) >
                0) {
          current = c;
        }
      }
      if (current == null) return;
      final curAmt = (current['last_amount'] as num?)?.toDouble() ?? 0.0;
      final curCur = (current['currency'] ?? 'USD').toString();
      final curDate = (current['last_charge_date'] ?? '').toString();
      // Prior price = the highest-priced earlier same-currency cluster that's
      // still cheaper than the current one (the closest previous price).
      Map? prior;
      for (final c in clusters) {
        if (identical(c, current)) continue;
        if ((c['currency'] ?? 'USD').toString() != curCur) continue;
        final amt = (c['last_amount'] as num?)?.toDouble() ?? 0.0;
        if (amt >= curAmt) continue;
        if ((c['last_charge_date'] ?? '').toString().compareTo(curDate) >= 0) {
          continue;
        }
        if (prior == null ||
            amt > ((prior['last_amount'] as num?)?.toDouble() ?? 0.0)) {
          prior = c;
        }
      }
      if (prior == null) return;
      final priorAmt = (prior['last_amount'] as num?)?.toDouble() ?? 0.0;
      if (priorAmt <= 0) return;
      final jump = (curAmt - priorAmt) / priorAmt;
      if (jump < 0.08 || (curAmt - priorAmt) < 1.0) return;
      hikes.add((
        merchant: (current['merchant'] ?? '').toString(),
        now: curAmt,
        was: priorAmt,
        cur: curCur,
      ));
    });
    // Largest absolute increase first; cap at three.
    hikes.sort((a, b) => (b.now - b.was).compareTo(a.now - a.was));
    for (final h in hikes.take(3)) {
      out.add(AppNotification(
        id: 'sub_price_up:${h.merchant.toLowerCase()}:${h.now.toStringAsFixed(2)}',
        icon: Icons.price_change_outlined,
        accent: Colors.amber,
        title: l.lwNotifSubPriceUpTitle(h.merchant),
        detail: l.lwNotifSubPriceUpDetail(
            money(h.now, h.cur), money(h.was, h.cur)),
        onTap: onJumpToSpending,
      ));
    }
  }

  return out;
}

/// Bell icon for the AppBar with a dot badge and a popover panel of
/// notifications. Counts and surfacing logic come from
/// [deriveNotifications]; the parent just supplies the inputs.
class NotificationsBell extends StatelessWidget {
  final List<AppNotification> notifications;

  /// Ids the user has already marked as read. The badge only lights for
  /// notifications whose id is NOT in this set, so persistent conditions
  /// (stale sync, overdue loan) stop nagging once acknowledged.
  final Set<String> dismissedIds;

  /// Marks every currently-shown notification as read. The parent persists
  /// the set (see Preferences.setDismissedNotifications) and rebuilds.
  final void Function(Set<String> currentIds)? onMarkAllRead;

  const NotificationsBell({
    super.key,
    required this.notifications,
    this.dismissedIds = const {},
    this.onMarkAllRead,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unseen =
        notifications.where((n) => !dismissedIds.contains(n.id)).toList();
    return PopupMenuButton<void>(
      tooltip: unseen.isEmpty
          ? l.lwNotifTooltipNone
          : l.lwNotifTooltipCount(unseen.length),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_none),
          if (unseen.isNotEmpty)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.orangeAccent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
      itemBuilder: (menuContext) {
        if (notifications.isEmpty) {
          return [
            PopupMenuItem(
              enabled: false,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.check_circle_outline,
                    color: context.positive),
                title: Text(l.lwNotifAllClear),
                subtitle: Text(l.lwNotifNoAlerts),
              ),
            ),
          ];
        }
        return [
          // Header: a "Mark all read" affordance, enabled only while
          // something is still unseen. Closing the menu first keeps the
          // pop animation clean before the parent rebuilds the badge.
          PopupMenuItem<void>(
            enabled: false,
            child: SizedBox(
              width: 360,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l.lwNotifHeader,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (unseen.isNotEmpty && onMarkAllRead != null)
                    TextButton(
                      onPressed: () {
                        Navigator.of(menuContext).pop();
                        onMarkAllRead!(
                            notifications.map((n) => n.id).toSet());
                      },
                      child: Text(l.lwNotifMarkAllRead),
                    ),
                ],
              ),
            ),
          ),
          ...notifications.map((n) {
            final isUnseen = !dismissedIds.contains(n.id);
            return PopupMenuItem<void>(
              onTap: n.onTap,
              child: SizedBox(
                width: 360,
                child: ListTile(
                  dense: true,
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: n.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(n.icon, color: n.accent, size: 16),
                  ),
                  title: Text(n.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(n.detail,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  // A small dot marks rows the user hasn't acknowledged yet;
                  // already-read rows stay visible but unmarked.
                  trailing: isUnseen
                      ? Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.orangeAccent,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
              ),
            );
          }),
        ];
      },
    );
  }
}
