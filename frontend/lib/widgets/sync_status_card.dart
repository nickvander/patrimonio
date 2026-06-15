import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';
import 'package:intl/intl.dart';

class SyncStatusCard extends StatelessWidget {
  final List<dynamic> syncData;
  final VoidCallback? onRetrySync;
  /// Optional targeted-retry hook. When provided, the "Retry N failed"
  /// shortcut loops this for each failed institution rather than calling
  /// the global onRetrySync (which syncs every institution).
  final Future<void> Function(String id)? onRetrySingle;
  /// Optional batched-retry hook. Preferred over [onRetrySingle] when
  /// provided — replaces N sequential HTTP calls with one round-trip.
  final Future<void> Function(List<String> ids)? onRetryBatch;
  final Function(String id)? onReconnect;
  final Function(String id)? onDelete;

  const SyncStatusCard({
    super.key,
    required this.syncData,
    this.onRetrySync,
    this.onRetrySingle,
    this.onRetryBatch,
    this.onReconnect,
    this.onDelete,
  });

  /// Ids of institutions stuck in error / failed state. We exclude
  /// `reconnect_required` because retry won't help — those need the
  /// Plaid Link reconnect flow, which is handled separately.
  List<String> _failedIds() {
    return syncData.where((raw) {
      if (raw is! Map) return false;
      final s = raw['sync_status']?.toString();
      return s == 'error' || s == 'failed';
    }).map((raw) => (raw as Map)['id'].toString()).toList();
  }

  /// Institutions that need a re-sync attempt — failed status, or stuck
  /// in `reconnect_required`. The `error`/`failed` ones can be retried in
  /// place; `reconnect_required` ones need the Plaid Link flow but show
  /// up in the count so the user knows total attention required.
  int get _failedCount {
    return syncData.where((raw) {
      if (raw is! Map) return false;
      final s = raw['sync_status']?.toString();
      return s == 'error' || s == 'failed' || s == 'reconnect_required';
    }).length;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final failed = _failedCount;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.lwSyncInstitutionsHeader,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textSubtle,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                if (failed > 0 &&
                    (onRetryBatch != null ||
                        onRetrySingle != null ||
                        onRetrySync != null))
                  TextButton.icon(
                    onPressed: () async {
                      final ids = _failedIds();
                      // Preference: batched > per-institution loop >
                      // global fallback. The batched path is one HTTP
                      // round-trip server-side via ANY($1).
                      if (onRetryBatch != null) {
                        try {
                          await onRetryBatch!(ids);
                        } catch (_) {/* swallowed; UI re-renders */}
                      } else if (onRetrySingle != null) {
                        for (final id in ids) {
                          try {
                            await onRetrySingle!(id);
                          } catch (_) {/* continue on individual errors */}
                        }
                      } else {
                        onRetrySync?.call();
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l.lwSyncRetryFailed(failed)),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orangeAccent,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            if (syncData.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    Icon(Icons.account_balance_outlined,
                        size: 32, color: context.textFaint),
                    const SizedBox(height: 8),
                    Text(
                      l.lwSyncNoInstitutions,
                      style: TextStyle(
                        color: context.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.lwSyncNoInstitutionsHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Icon(Icons.arrow_downward,
                        size: 18, color: context.textFaint),
                  ],
                ),
              )
            else
              ...syncData.map((inst) => _buildSyncRow(context, inst)),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncRow(BuildContext context, Map<String, dynamic> inst) {
    return LayoutBuilder(builder: (ctx, c) {
      final isNarrow = c.maxWidth < 420;
      return _buildSyncRowBody(context, inst, isNarrow);
    });
  }

  Widget _buildSyncRowBody(
      BuildContext context, Map<String, dynamic> inst, bool isNarrow) {
    final l = AppLocalizations.of(context);
    final status = inst['sync_status'] ?? 'unknown';

    IconData statusIcon;
    Color statusColor;

    switch (status) {
      case 'success':
      case 'synced':
        statusIcon = Icons.check_circle;
        statusColor = Colors.green;
        break;
      case 'syncing':
        statusIcon = Icons.sync;
        statusColor = Colors.lightBlueAccent;
        break;
      case 'setup_required':
        statusIcon = Icons.settings_suggest;
        statusColor = Colors.orangeAccent;
        break;
      case 'reconnect_required':
        statusIcon = Icons.link_off;
        statusColor = Colors.deepOrangeAccent;
        break;
      case 'error':
      case 'failed':
        statusIcon = Icons.error;
        statusColor = Colors.red;
        break;
      case 'pending':
        statusIcon = Icons.hourglass_empty;
        statusColor = Colors.orange;
        break;
      case 'manual':
        statusIcon = Icons.edit_note;
        statusColor = Colors.grey;
        break;
      default:
        statusIcon = Icons.help;
        statusColor = Colors.grey;
    }

    String lastSyncText = l.lwSyncNever;
    if (inst['last_synced_at'] != null) {
      final dt = DateTime.parse(inst['last_synced_at']).toLocal();
      lastSyncText = DateFormat('MMM d, h:mm a').format(dt);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        inst['name'] ?? l.lwSyncUnknownInstitution,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _statusDetail(context, inst, status, lastSyncText),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                      if (inst['last_sync_error'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            inst['last_sync_error'],
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.redAccent,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      else if (status == 'error' || status == 'failed')
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            l.lwSyncFailedUnknownReason,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.redAccent,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status == 'reconnect_required')
                isNarrow
                    ? IconButton(
                        onPressed: () => onReconnect?.call(inst['id']),
                        icon: const Icon(Icons.link,
                            color: Colors.deepOrangeAccent, size: 20),
                        tooltip: l.lwSyncReconnect,
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                      )
                    : TextButton.icon(
                        onPressed: () => onReconnect?.call(inst['id']),
                        icon: const Icon(Icons.link, size: 16),
                        label: Text(l.lwSyncReconnect),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.deepOrangeAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
              if ([
                'error',
                'failed',
                'setup_required',
              ].contains(status))
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.teal, size: 20),
                  onPressed: onRetrySync,
                  tooltip: l.lwSyncRetrySync,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Colors.redAccent, size: 20),
                onPressed: () => onDelete?.call(inst['id']),
                tooltip: l.lwSyncDeleteInstitution,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusDetail(
    BuildContext context,
    Map<String, dynamic> inst,
    String status,
    String lastSyncText,
  ) {
    final l = AppLocalizations.of(context);
    final source = l.lwSyncVia(inst['integration_type'].toString());
    switch (status) {
      case 'syncing':
        return '$source • ${l.lwSyncDetailSyncingNow}';
      case 'setup_required':
        return '$source • ${l.lwSyncDetailSetupRequired}';
      case 'reconnect_required':
        return '$source • ${l.lwSyncDetailReconnectRequired}';
      case 'pending':
        return '$source • ${l.lwSyncDetailWaitingFirstSync}';
      case 'manual':
        return '$source • ${l.lwSyncDetailManualSource}';
      default:
        bool isStale = false;
        if (inst['last_synced_at'] != null) {
          final dt = DateTime.parse(inst['last_synced_at']);
          isStale = DateTime.now().difference(dt).inHours > 24;
        }
        return '$source • $lastSyncText${isStale ? " ${l.lwSyncStaleSuffix}" : ""}';
    }
  }
}
