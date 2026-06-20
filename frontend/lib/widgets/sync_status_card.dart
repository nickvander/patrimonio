import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';
import 'package:intl/intl.dart';

class SyncStatusCard extends StatefulWidget {
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

  @override
  State<SyncStatusCard> createState() => _SyncStatusCardState();
}

class _SyncStatusCardState extends State<SyncStatusCard> {
  /// When true, the visible list is filtered down to institutions needing
  /// attention (error / reconnect_required / stale). Local UI state only.
  bool _problemsOnly = false;

  List<dynamic> get _syncData => widget.syncData;

  /// Ids of institutions stuck in error / failed state. We exclude
  /// `reconnect_required` because retry won't help — those need the
  /// Plaid Link reconnect flow, which is handled separately.
  List<String> _failedIds() {
    return _syncData.where((raw) {
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
    return _syncData.where((raw) {
      if (raw is! Map) return false;
      final s = raw['sync_status']?.toString();
      return s == 'error' || s == 'failed' || s == 'reconnect_required';
    }).length;
  }

  /// Count institutions whose [sync_status] matches any in [statuses].
  int _statusCount(Set<String> statuses) {
    return _syncData.where((raw) {
      if (raw is! Map) return false;
      return statuses.contains(raw['sync_status']?.toString());
    }).length;
  }

  /// True when [inst]'s last successful sync is older than 24h. Mirrors the
  /// staleness rule used per-row in [_statusDetail]. Institutions that have
  /// never synced (no timestamp) are not counted here — they surface via
  /// their own status (pending / setup_required).
  bool _isStale(Map raw) {
    final ts = raw['last_synced_at'];
    if (ts == null) return false;
    final dt = DateTime.tryParse(ts.toString());
    if (dt == null) return false;
    return DateTime.now().difference(dt).inHours > 24;
  }

  /// Count of stale-but-otherwise-fine institutions: a synced/success
  /// institution whose data is more than 24h old. We exclude rows already
  /// counted as error/reconnect so badges don't double-count.
  int get _staleCount {
    return _syncData.where((raw) {
      if (raw is! Map) return false;
      final s = raw['sync_status']?.toString();
      if (s == 'error' || s == 'failed' || s == 'reconnect_required') {
        return false;
      }
      return _isStale(raw);
    }).length;
  }

  /// True when an institution should be shown while the problem filter is on:
  /// error / failed / reconnect_required, or stale.
  bool _isProblem(Map raw) {
    final s = raw['sync_status']?.toString();
    if (s == 'error' || s == 'failed' || s == 'reconnect_required') {
      return true;
    }
    return _isStale(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final failed = _failedCount;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    final successCount = _statusCount({'success', 'synced'});
    final syncingCount = _statusCount({'syncing'});
    final errorCount = _statusCount({'error', 'failed'});
    final reconnectCount = _statusCount({'reconnect_required'});
    final staleCount = _staleCount;
    final problemTotal = errorCount + reconnectCount + staleCount;

    final visible = _problemsOnly
        ? _syncData
            .where((raw) => raw is Map && _isProblem(raw))
            .toList()
        : _syncData;

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
                    (widget.onRetryBatch != null ||
                        widget.onRetrySingle != null ||
                        widget.onRetrySync != null))
                  TextButton.icon(
                    onPressed: () async {
                      final ids = _failedIds();
                      // Preference: batched > per-institution loop >
                      // global fallback. The batched path is one HTTP
                      // round-trip server-side via ANY($1).
                      if (widget.onRetryBatch != null) {
                        try {
                          await widget.onRetryBatch!(ids);
                        } catch (_) {/* swallowed; UI re-renders */}
                      } else if (widget.onRetrySingle != null) {
                        for (final id in ids) {
                          try {
                            await widget.onRetrySingle!(id);
                          } catch (_) {/* continue on individual errors */}
                        }
                      } else {
                        widget.onRetrySync?.call();
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l.lwSyncRetryFailed(failed)),
                    style: TextButton.styleFrom(
                      foregroundColor: context.warning,
                    ),
                  ),
              ],
            ),
            if (_syncData.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildSummaryRow(
                context,
                successCount: successCount,
                syncingCount: syncingCount,
                errorCount: errorCount,
                reconnectCount: reconnectCount,
                staleCount: staleCount,
                problemTotal: problemTotal,
              ),
            ],
            const SizedBox(height: 24),
            if (_syncData.isEmpty)
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
                        color: context.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Icon(Icons.arrow_downward,
                        size: 18, color: context.textFaint),
                  ],
                ),
              )
            else if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    l.lwSyncNoProblems,
                    style: TextStyle(
                      color: context.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
            else
              ...visible.map((inst) => _buildSyncRow(context, inst)),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(
    BuildContext context, {
    required int successCount,
    required int syncingCount,
    required int errorCount,
    required int reconnectCount,
    required int staleCount,
    required int problemTotal,
  }) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (successCount > 0)
          _statusBadge(context, Icons.check_circle, context.positive,
              '${l.lwSyncBadgeSuccess}: $successCount'),
        if (syncingCount > 0)
          _statusBadge(context, Icons.sync, context.info,
              '${l.lwSyncBadgeSyncing}: $syncingCount'),
        if (errorCount > 0)
          _statusBadge(context, Icons.error, context.negative,
              '${l.lwSyncBadgeError}: $errorCount'),
        if (reconnectCount > 0)
          _statusBadge(context, Icons.link_off, context.warning,
              '${l.lwSyncBadgeReconnect}: $reconnectCount'),
        if (staleCount > 0)
          _statusBadge(context, Icons.schedule, context.warning,
              '${l.lwSyncBadgeStale}: $staleCount'),
        if (problemTotal > 0)
          FilterChip(
            selected: _problemsOnly,
            onSelected: (v) => setState(() => _problemsOnly = v),
            avatar: Icon(
              Icons.filter_alt_outlined,
              size: 16,
              color: _problemsOnly ? context.warning : context.textMuted,
            ),
            label: Text(l.lwSyncFilterProblems),
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _problemsOnly ? context.warning : context.textMuted,
            ),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );
  }

  Widget _statusBadge(
      BuildContext context, IconData icon, Color color, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
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
        statusColor = context.positive;
        break;
      case 'syncing':
        statusIcon = Icons.sync;
        statusColor = context.info;
        break;
      case 'setup_required':
        statusIcon = Icons.settings_suggest;
        statusColor = context.warning;
        break;
      case 'reconnect_required':
        statusIcon = Icons.link_off;
        statusColor = context.warning;
        break;
      case 'error':
      case 'failed':
        statusIcon = Icons.error;
        statusColor = context.negative;
        break;
      case 'pending':
        statusIcon = Icons.hourglass_empty;
        statusColor = context.warning;
        break;
      case 'manual':
        statusIcon = Icons.edit_note;
        statusColor = context.textMuted;
        break;
      default:
        statusIcon = Icons.help;
        statusColor = context.textMuted;
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
                          color: context.textMuted,
                        ),
                      ),
                      if (inst['last_sync_error'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            inst['last_sync_error'],
                            style: TextStyle(
                              fontSize: 11,
                              color: context.negative,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      else if (status == 'error' || status == 'failed')
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            l.lwSyncFailedUnknownReason,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.negative,
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
                        onPressed: () => widget.onReconnect?.call(inst['id']),
                        icon: Icon(Icons.link,
                            color: context.warning, size: 20),
                        tooltip: l.lwSyncReconnect,
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                      )
                    : TextButton.icon(
                        onPressed: () => widget.onReconnect?.call(inst['id']),
                        icon: const Icon(Icons.link, size: 16),
                        label: Text(l.lwSyncReconnect),
                        style: TextButton.styleFrom(
                          foregroundColor: context.warning,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
              if ([
                'error',
                'failed',
                'setup_required',
              ].contains(status))
                IconButton(
                  icon: Icon(Icons.refresh, color: context.info, size: 20),
                  onPressed: widget.onRetrySync,
                  tooltip: l.lwSyncRetrySync,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    color: context.negative, size: 20),
                onPressed: () => widget.onDelete?.call(inst['id']),
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
