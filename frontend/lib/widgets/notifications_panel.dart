import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme/palette.dart';
import '../utils/account_category.dart';
import '../utils/category.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

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

  /// When the notification was recorded, for inbox rows that come from
  /// the server's `user_notifications` store. Null for condition-derived
  /// rows (a stale sync "is" stale — it didn't happen at an instant).
  final DateTime? createdAt;

  AppNotification({
    required this.id,
    required this.icon,
    required this.accent,
    required this.title,
    required this.detail,
    this.onTap,
    this.createdAt,
  });
}

/// Id prefix for rows backed by a server `user_notifications` row. The
/// dashboard splits on this to route read-state: `srv:` ids are marked
/// read via POST /api/notifications/read; everything else goes to the
/// localStorage dismissed-ids set.
const String kServerNotificationIdPrefix = 'srv:';

/// Map `GET /api/notifications` rows (the server-side inbox: FX alert
/// crossings, import-staleness reminders, loan payment due reminders —
/// whatever fx-center/staleness/loans wrote) into bell rows, so every
/// source appears in one list. Title/body are stored server-side in
/// English (see the backend writers); icon, accent and deep link are
/// derived locale-independently from `kind`, with a neutral fallback for
/// kinds this build doesn't know yet (an older app against a newer
/// server must render, not crash).
List<AppNotification> serverNotificationsToApp({
  required List<dynamic> rows,
  Brightness brightness = Brightness.dark,
  /// Opens the FX center sheet (fx_alert rows deep-link to their subject).
  VoidCallback? onOpenFxCenter,
  /// Jump to Management/sync (import_stale rows: the fix is an import).
  VoidCallback? onJumpToManagement,
  /// Jump to the Lending tab (loan_due rows).
  VoidCallback? onJumpToLending,
}) {
  final out = <AppNotification>[];
  for (final raw in rows) {
    if (raw is! Map) continue;
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) continue;
    final kind = (raw['kind'] ?? '').toString();
    final (IconData icon, Color accent, VoidCallback? onTap) = switch (kind) {
      'fx_alert' => (
          Icons.currency_exchange,
          BrandPalette.info(brightness),
          onOpenFxCenter,
        ),
      'import_stale' => (
          Icons.upload_file,
          BrandPalette.warning(brightness),
          onJumpToManagement,
        ),
      'loan_due' => (
          Icons.event,
          BrandPalette.warning(brightness),
          onJumpToLending,
        ),
      _ => (Icons.notifications_none, BrandPalette.neutral(brightness), null),
    };
    out.add(AppNotification(
      id: '$kServerNotificationIdPrefix$id',
      icon: icon,
      accent: accent,
      title: (raw['title'] ?? '').toString(),
      detail: (raw['body'] ?? '').toString(),
      onTap: onTap,
      createdAt: DateTime.tryParse(raw['created_at']?.toString() ?? ''),
    ));
  }
  return out;
}

/// Pure derivation: walks the existing sync data + net-worth history and
/// emits notification rows for the conditions the user cares about. Lives
/// in widget code rather than the API because all the inputs are already
/// in memory client-side.
List<AppNotification> deriveNotifications({
  required AppLocalizations l,
  /// Active theme brightness — resolves each row's accent to its
  /// AA-passing shade for the current theme (via `BrandPalette`). Defaults
  /// to dark (the historical neon look) so context-less callers/tests keep
  /// working; the live bell passes `Theme.of(context).brightness`.
  Brightness brightness = Brightness.dark,
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
  /// Accounts the sync auto-archived because Plaid stopped returning them
  /// (the account was closed at the bank). From GET /api/accounts/archived.
  /// Each item: {id, name, nickname, institution_name, account_type,
  /// current_balance, currency, archived_at}.
  List<dynamic> archivedAccounts = const [],
  /// Opens the Hidden/closed items screen when an archived-account row is
  /// tapped (where the user can restore or remove it).
  VoidCallback? onJumpToClosedAccounts,
  /// "What changed since your last visit" payload from
  /// GET /api/dashboard/since-last-login (same data as the Overview
  /// banner): {previous_login_at, new_transactions, largest_move?,
  /// sync_errors}. Null when there's no anchor yet (first-ever login) or
  /// the fetch failed — the digest rows simply don't appear.
  Map<String, dynamic>? sinceLastLogin,
  /// Jump to the Transactions tab pre-filtered to "since [anchor]" when a
  /// digest row is tapped. Receives the previous-login anchor.
  void Function(DateTime anchor)? onJumpToTransactions,
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
        accent: BrandPalette.negative(brightness),
        title: l.lwNotifRepaymentOverdueTitle(borrower),
        // gen-l10n orders these alphabetically → (amount, daysOverdue, dueDate, number).
        detail: l.lwNotifRepaymentOverdueDetail(
            money(amount, cur), overdue, dueStr, n),
        onTap: onJumpToLending,
      ));
    } else if (until > 0) {
      out.add(AppNotification(
        id: 'loan_due:$borrower:$n',
        icon: Icons.event,
        accent: BrandPalette.warning(brightness),
        title: l.lwNotifRepaymentDueTitle(borrower, until),
        // gen-l10n orders these alphabetically → (amount, dueDate, number).
        detail: l.lwNotifRepaymentDueDetail(money(amount, cur), dueStr, n),
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
        accent: BrandPalette.warning(brightness),
        title: l.lwNotifRepaymentDueTodayTitle(borrower),
        // gen-l10n orders these alphabetically → (amount, number); pass amount first.
        detail: l.lwNotifRepaymentDueTodayDetail(money(amount, cur), n),
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
        accent: BrandPalette.warning(brightness),
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
        accent: BrandPalette.warning(brightness),
        title: l.lwNotifNeedsReconnectTitle(name),
        detail: l.lwNotifNeedsReconnectDetail,
        onTap: onJumpToManagement,
      ));
    } else if (status == 'error' || status == 'failed') {
      out.add(AppNotification(
        id: 'sync_failed:$name',
        icon: Icons.error_outline,
        accent: BrandPalette.negative(brightness),
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
              accent: BrandPalette.warning(brightness),
              // gen-l10n orders these alphabetically → (days, name); pass days first.
              title: l.lwNotifStaleSyncTitle(days, name),
              detail: l.lwNotifStaleSyncDetail,
              onTap: onJumpToManagement,
            ));
          }
        }
      }
    }
  }

  // 2) Net worth since last sync — a bidirectional "your net worth moved
  //    since the previous snapshot" row. We compare the latest snapshot to the
  //    most recent EARLIER one with a different date (the prior sync), so the
  //    alert tracks real activity rather than an arbitrary 30-day window.
  //    netWorthHistory is USD-normalised, so amounts are formatted as USD.
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
    final latestDateStr = latest['date']?.toString() ?? '';
    final latestDt = DateTime.tryParse(latestDateStr) ?? DateTime.now();
    // Walk back to the most recent snapshot on a DIFFERENT date — that's the
    // prior sync. Skipping same-date rows keeps intra-day re-syncs from
    // reading as a zero-delta against themselves.
    Map<String, dynamic>? prior;
    for (final p in sorted.reversed) {
      if (identical(p, latest)) continue;
      if ((p['date']?.toString() ?? '') == latestDateStr) continue;
      prior = p as Map<String, dynamic>;
      break;
    }
    if (prior != null) {
      final priorNw = (prior['net_worth'] as num?)?.toDouble() ?? 0.0;
      if (priorNw > 0) {
        final delta = latestNw - priorNw;
        final pct = (delta / priorNw) * 100;
        // Stay quiet on a flat day — a sub-0.25% wobble isn't worth a badge.
        if (pct.abs() >= 0.25) {
          final amount = money(delta.abs(), 'USD');
          final pctStr = formatPercentLocale(l.localeName, pct.abs(), digits: 1);
          final detail =
              l.lwNotifNetWorthSinceSyncDetail(DateFormat('MMM d').format(latestDt));
          final up = delta >= 0;
          out.add(AppNotification(
            id: 'net_worth_since_sync:$latestDateStr',
            icon: up ? Icons.trending_up : Icons.trending_down,
            accent: up
                ? BrandPalette.teal(brightness)
                : (pct.abs() >= 5
                    ? BrandPalette.negative(brightness)
                    : BrandPalette.warning(brightness)),
            title: up
                ? l.lwNotifNetWorthUpTitle(amount, pctStr)
                : l.lwNotifNetWorthDownTitle(amount, pctStr),
            detail: detail,
          ));
        }
      }
    }
  }

  // 2b) Since-last-visit digest — the same "what changed while you were
  //     away" data the Overview banner shows (new transactions, biggest
  //     single-account move), surfaced as bell rows so the inbox is the
  //     one place that collects everything. Ids are keyed on the anchor
  //     (previous_login_at): a new login produces a new anchor, so the
  //     rows re-alert; re-renders within one session stay read.
  //     sync_errors from the digest are deliberately NOT emitted here —
  //     section 1 above already surfaces live sync problems and a
  //     duplicate row would double-badge the same condition.
  final sinceAnchorIso = sinceLastLogin?['previous_login_at']?.toString();
  final sinceAnchor =
      sinceAnchorIso != null ? DateTime.tryParse(sinceAnchorIso) : null;
  if (sinceAnchor != null) {
    final anchorStr = DateFormat('MMM d').format(sinceAnchor.toLocal());
    final newTx = (sinceLastLogin?['new_transactions'] as num?)?.toInt() ?? 0;
    if (newTx > 0) {
      out.add(AppNotification(
        id: 'since_tx:$sinceAnchorIso',
        icon: Icons.receipt_long,
        accent: BrandPalette.info(brightness),
        title: l.lwSinceNewTransactions(newTx),
        detail: l.lwNotifSinceVisitDetail(anchorStr),
        onTap: onJumpToTransactions == null
            ? null
            : () => onJumpToTransactions(sinceAnchor),
      ));
    }
    final move = sinceLastLogin?['largest_move'];
    if (move is Map) {
      final deltaUsd = (move['delta_usd'] as num?)?.toDouble() ?? 0.0;
      final account =
          (move['account_name'] ?? l.lwNotifAccountFallback).toString();
      if (deltaUsd != 0) {
        final up = deltaUsd >= 0;
        final signed =
            '${up ? '+' : '−'}${money(deltaUsd.abs(), 'USD')}';
        out.add(AppNotification(
          id: 'since_move:$sinceAnchorIso',
          icon: up ? Icons.trending_up : Icons.trending_down,
          accent: up
              ? BrandPalette.teal(brightness)
              : BrandPalette.warning(brightness),
          // gen-l10n orders these alphabetically → (account, amount).
          title: l.lwSinceLargestMove(account, signed),
          detail: l.lwNotifSinceVisitDetail(anchorStr),
          onTap: onJumpToTransactions == null
              ? null
              : () => onJumpToTransactions(sinceAnchor),
        ));
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
        accent: BrandPalette.warning(brightness),
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
        accent: BrandPalette.warning(brightness),
        title: l.lwNotifSubPriceUpTitle(h.merchant),
        detail: l.lwNotifSubPriceUpDetail(
            money(h.now, h.cur), money(h.was, h.cur)),
        onTap: onJumpToSpending,
      ));
    }
  }

  // 5) Account auto-archived — the sync stopped seeing an account at the bank
  //    (Plaid no longer returns it, i.e. it was closed) and archived it. Only
  //    surface recent archivals (last 30 days) so an old close-out doesn't
  //    linger in the bell forever. Rows with an unparseable archived_at are
  //    skipped rather than guessed.
  for (final raw in archivedAccounts) {
    if (raw is! Map) continue;
    final archivedAt =
        DateTime.tryParse(raw['archived_at']?.toString() ?? '');
    if (archivedAt == null) continue;
    if (DateTime.now().difference(archivedAt).inDays > 30) continue;
    final id = raw['id']?.toString();
    if (id == null) continue;
    final institution =
        (raw['institution_name'] ?? l.lwNotifInstitutionFallback).toString();
    final name = (raw['nickname']?.toString().trim().isNotEmpty ?? false)
        ? raw['nickname'].toString()
        : (raw['name'] ?? l.lwNotifAccountFallback).toString();
    out.add(AppNotification(
      id: 'account_archived:$id',
      icon: Icons.link_off,
      accent: BrandPalette.neutral(brightness),
      title: l.lwNotifAccountArchivedTitle(institution),
      detail: l.lwNotifAccountArchivedDetail(name, institution),
      onTap: onJumpToClosedAccounts,
    ));
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

  /// Fired when the panel opens (popup or sheet), with the ids of every
  /// currently-shown notification. The dashboard uses it to mark the
  /// inbox read ("opening the panel marks read"): server-backed rows via
  /// POST /api/notifications/read, derived rows via the dismissed-ids
  /// set. The open panel itself keeps rendering the pre-open snapshot,
  /// so the unread dots stay visible for this viewing; the badge clears
  /// once the panel closes.
  final void Function(Set<String> currentIds)? onOpened;

  const NotificationsBell({
    super.key,
    required this.notifications,
    this.dismissedIds = const {},
    this.onMarkAllRead,
    this.onOpened,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unseen =
        notifications.where((n) => !dismissedIds.contains(n.id)).toList();
    final tooltip = unseen.isEmpty
        ? l.lwNotifTooltipNone
        : l.lwNotifTooltipCount(unseen.length);

    // Phones open a full-width bottom sheet. A dropdown anchored to a
    // top-corner bell was cramped on a narrow screen — clipped rows and an
    // easy-to-miss popover meant the alerts were effectively invisible on
    // mobile. Desktop keeps the quick anchored dropdown.
    final isNarrow = MediaQuery.sizeOf(context).width < 600;
    if (isNarrow) {
      return IconButton(
        tooltip: tooltip,
        icon: _bellIcon(context, unseen.length),
        onPressed: () => _openSheet(context, l, unseen),
      );
    }

    return PopupMenuButton<void>(
      tooltip: tooltip,
      icon: _bellIcon(context, unseen.length),
      // Anchor the panel BELOW the bell (i.e. below the app bar). The
      // default `over` position opened the menu on top of the button,
      // covering the app bar and looking detached from the bell that
      // spawned it — the long-standing anchoring complaint.
      position: PopupMenuPosition.under,
      onOpened: () =>
          onOpened?.call(notifications.map((n) => n.id).toSet()),
      itemBuilder: (menuContext) {
        if (notifications.isEmpty) {
          return [
            PopupMenuItem(
              enabled: false,
              padding: EdgeInsets.zero,
              child: SizedBox(width: 380, child: _emptyState(context, l)),
            ),
          ];
        }
        return [
          // Header: a "Mark all read" affordance, enabled only while
          // something is still unseen. Closing the menu first keeps the
          // pop animation clean before the parent rebuilds the badge.
          PopupMenuItem<void>(
            enabled: false,
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 380,
              child: _header(context, l, unseen,
                  onClose: () => Navigator.of(menuContext).pop()),
            ),
          ),
          ...notifications.map((n) {
            final isUnseen = !dismissedIds.contains(n.id);
            return PopupMenuItem<void>(
              onTap: n.onTap,
              padding: EdgeInsets.zero,
              child: SizedBox(width: 380, child: _row(context, n, isUnseen)),
            );
          }),
        ];
      },
    );
  }

  /// The bell glyph + unread-count badge, shared by the mobile button and
  /// the desktop dropdown trigger. A numeric count (not just a dot) so
  /// "3 things need attention" is visible without opening the panel;
  /// capped at 9+ to keep the pill inside the 24dp icon box.
  Widget _bellIcon(BuildContext context, int unseenCount) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.notifications_none),
        if (unseenCount > 0)
          Positioned(
            right: -5,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3.5),
              constraints: const BoxConstraints(minWidth: 14),
              height: 14,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.warning,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
              child: Text(
                unseenCount > 9 ? '9+' : '$unseenCount',
                style: TextStyle(
                  fontSize: 8,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  // On the warning fill, the surface color is the
                  // high-contrast pair in both brightnesses (same trick
                  // as the badge border).
                  color: Theme.of(context).colorScheme.surface,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _openSheet(
    BuildContext context,
    AppLocalizations l,
    List<AppNotification> unseen,
  ) {
    // Same "opening marks read" semantics as the desktop popup — the
    // sheet below renders from the snapshot captured right here, so the
    // unread dots survive for this viewing.
    onOpened?.call(notifications.map((n) => n.id).toSet());
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(context, l, unseen,
                    onClose: () => Navigator.of(sheetCtx).pop()),
                Divider(height: 1, color: context.hairline),
                if (notifications.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _emptyState(context, l),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: notifications.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: context.hairline),
                      itemBuilder: (_, i) {
                        final n = notifications[i];
                        final isUnseen = !dismissedIds.contains(n.id);
                        return InkWell(
                          onTap: n.onTap == null
                              ? null
                              : () {
                                  Navigator.of(sheetCtx).pop();
                                  n.onTap!();
                                },
                          child: _row(context, n, isUnseen),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shared header: title + "Mark all read". [onClose] dismisses the host
  /// surface (popup or sheet) before the parent rebuilds the badge.
  Widget _header(
    BuildContext context,
    AppLocalizations l,
    List<AppNotification> unseen, {
    required VoidCallback onClose,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l.lwNotifHeader,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: context.textPrimary,
              )),
          if (unseen.isNotEmpty && onMarkAllRead != null)
            TextButton(
              onPressed: () {
                onClose();
                onMarkAllRead!(notifications.map((n) => n.id).toSet());
              },
              child: Text(l.lwNotifMarkAllRead),
            ),
        ],
      ),
    );
  }

  /// One readable notification row — roomy tap target, two-line title and
  /// up-to-three-line detail at a legible size (the old `dense` ListTile
  /// truncated hard and read as fine print).
  Widget _row(BuildContext context, AppNotification n, bool isUnseen) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: n.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(n.icon, color: n.accent, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  n.detail,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.3,
                    color: context.textSubtle,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                // Inbox rows carry the moment they were recorded;
                // condition-derived rows (createdAt == null) don't — a
                // "sync is stale" condition has no meaningful timestamp.
                if (n.createdAt != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    DateFormat.MMMd(
                      Localizations.localeOf(context).toString(),
                    ).format(n.createdAt!.toLocal()),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // A small dot marks rows the user hasn't acknowledged yet;
          // already-read rows stay visible but unmarked.
          if (isUnseen) ...[
            const SizedBox(width: 8),
            Container(
              margin: const EdgeInsets.only(top: 5),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: context.warning,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, AppLocalizations l) {
    return ListTile(
      leading: Icon(Icons.check_circle_outline, color: context.positive),
      title: Text(l.lwNotifAllClear),
      subtitle: Text(l.lwNotifNoAlerts),
    );
  }
}
