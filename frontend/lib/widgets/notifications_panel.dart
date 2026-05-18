import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/theme_colors.dart';

/// One notification row shown in the bell-icon popover.
class AppNotification {
  final IconData icon;
  final Color accent;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  AppNotification({
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
  required List<dynamic> syncData,
  required List<dynamic> netWorthHistory,
  required VoidCallback onJumpToManagement,
}) {
  final out = <AppNotification>[];

  // 1) Sync issues — anything not "synced" or "manual" earns a row.
  for (final raw in syncData) {
    if (raw is! Map) continue;
    final status = raw['sync_status']?.toString();
    final name = (raw['name'] ?? 'Institution').toString();
    if (status == 'reconnect_required') {
      out.add(AppNotification(
        icon: Icons.link_off,
        accent: Colors.orangeAccent,
        title: '$name needs reconnect',
        detail: 'Plaid token expired — reconnect to resume sync.',
        onTap: onJumpToManagement,
      ));
    } else if (status == 'error' || status == 'failed') {
      out.add(AppNotification(
        icon: Icons.error_outline,
        accent: Colors.redAccent,
        title: '$name sync failed',
        detail: (raw['last_sync_error'] ?? 'Unknown sync error').toString(),
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
              icon: Icons.access_time,
              accent: Colors.amber,
              title: '$name last synced ${days}d ago',
              detail:
                  'Trigger a sync to pull in transactions and balance updates.',
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
            icon: Icons.trending_down,
            accent: Colors.redAccent,
            title:
                'Net worth dropped ${pct.toStringAsFixed(1)}% in 30 days',
            detail:
                'Latest ${DateFormat('MMM d').format(latestDt)} vs ${DateFormat('MMM d').format(DateTime.tryParse(ref['date']?.toString() ?? '') ?? latestDt)}.',
          ));
        }
      }
    }
  }

  return out;
}

/// Bell icon for the AppBar with a dot badge and a popover panel of
/// notifications. Counts and surfacing logic come from
/// [deriveNotifications]; the parent just supplies the inputs.
class NotificationsBell extends StatelessWidget {
  final List<AppNotification> notifications;
  const NotificationsBell({super.key, required this.notifications});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'Notifications',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_none),
          if (notifications.isNotEmpty)
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
      itemBuilder: (_) {
        if (notifications.isEmpty) {
          return [
            PopupMenuItem(
              enabled: false,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.check_circle_outline,
                    color: context.positive),
                title: const Text('All clear'),
                subtitle: const Text('No alerts right now.'),
              ),
            ),
          ];
        }
        return notifications
            .map((n) => PopupMenuItem<void>(
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
                    ),
                  ),
                ))
            .toList();
      },
    );
  }
}
