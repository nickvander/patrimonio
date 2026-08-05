import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

/// Entries of a per-institution overflow menu. A single-value enum today,
/// but the kebab is the place any future rare per-row action goes rather
/// than growing the always-visible icon strip.
enum _RowAction { fullResync }

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

  /// Optional full-history re-pull hook (`POST /institutions/{id}/resync`).
  /// Offered ONLY on Plaid rows, behind a confirmation — see
  /// [_confirmFullResync]. The host is responsible for the call itself and
  /// for reflecting the resulting sync through this same card's data.
  final Future<void> Function(String id)? onFullResync;

  const SyncStatusCard({
    super.key,
    required this.syncData,
    this.onRetrySync,
    this.onRetrySingle,
    this.onRetryBatch,
    this.onReconnect,
    this.onDelete,
    this.onFullResync,
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
    return _syncData
        .where((raw) {
          if (raw is! Map) return false;
          final s = raw['sync_status']?.toString();
          return s == 'error' || s == 'failed';
        })
        .map((raw) => (raw as Map)['id'].toString())
        .toList();
  }

  /// Institutions the "Retry failed" button will actually re-sync. MUST
  /// equal [_failedIds] — a `reconnect_required` (e.g. a locked E*Trade
  /// item) was being counted here but excluded from the retry batch, so
  /// the button fired an empty request and did nothing. Locked items are
  /// surfaced by their own per-row Reconnect action instead.
  int get _failedCount => _failedIds().length;

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

  /// True when [inst] is a Plaid-backed institution. Only these have a
  /// `/transactions/sync` cursor to clear, so only these can be re-pulled;
  /// the backend answers 400 for anything else.
  bool _isPlaid(Map inst) => inst['integration_type']?.toString() == 'plaid';

  /// Confirmation for the full-history re-pull, then hand off to the host.
  ///
  /// The copy has to stay honest in both directions. A re-pull replays what
  /// the provider still holds, so it CAN recover a row the incremental
  /// cursor skipped — but it cannot conjure one the provider has dropped
  /// from its feed, and promising recovery here would turn "your rent is
  /// gone" into "the app lied to me". What IS guaranteed is that nothing of
  /// the user's is lost: the backend's upsert touches no `user_*` column, so
  /// edits, renames and rule-applied categories survive.
  Future<void> _confirmFullResync(
    BuildContext context,
    Map<String, dynamic> inst,
  ) async {
    final l = AppLocalizations.of(context);
    final name = inst['name']?.toString() ?? l.lwSyncUnknownInstitution;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // gen-l10n orders placeholders alphabetically; single placeholder
        // (name), so there is nothing to transpose here.
        title: Text(l.lwSyncResyncTitle(name)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.lwSyncResyncWhat),
              const SizedBox(height: 12),
              // The limitation is the point of this dialog, so it is styled
              // as a warning rather than buried as fine print.
              Text(
                l.lwSyncResyncLimit,
                style: TextStyle(color: context.warning),
              ),
              const SizedBox(height: 12),
              Text(
                l.lwSyncResyncSafe,
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.lwSyncResyncConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onFullResync?.call(inst['id'].toString());
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

    final successCount = _statusCount({'success', 'synced'});
    final syncingCount = _statusCount({'syncing'});
    final errorCount = _statusCount({'error', 'failed'});
    final reconnectCount = _statusCount({'reconnect_required'});
    final staleCount = _staleCount;
    final problemTotal = errorCount + reconnectCount + staleCount;

    final visible = _problemsOnly
        ? _syncData.where((raw) => raw is Map && _isProblem(raw)).toList()
        : _syncData;

    // Card padding off the card's OWN LayoutBuilder constraint, never
    // the window (skill §4/§5): the card is narrower than the screen on
    // every layout that pads or column-clamps its tab.
    return LayoutBuilder(
      builder: (_, outer) {
        final pad = outer.maxWidth < 720 ? 16.0 : 24.0;
        return Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
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
                          if (ids.isEmpty) return; // nothing retryable
                          // Preference: batched > per-institution loop >
                          // global fallback. The batched path is one HTTP
                          // round-trip server-side via ANY($1).
                          if (widget.onRetryBatch != null) {
                            try {
                              await widget.onRetryBatch!(ids);
                            } catch (_) {
                              /* swallowed; UI re-renders */
                            }
                          } else if (widget.onRetrySingle != null) {
                            for (final id in ids) {
                              try {
                                await widget.onRetrySingle!(id);
                              } catch (_) {
                                /* continue on individual errors */
                              }
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
                        Icon(
                          Icons.account_balance_outlined,
                          size: 32,
                          color: context.textFaint,
                        ),
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
                        Icon(
                          Icons.arrow_downward,
                          size: 18,
                          color: context.textFaint,
                        ),
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
      },
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
          _statusBadge(
            context,
            Icons.check_circle,
            context.positive,
            '${l.lwSyncBadgeSuccess}: $successCount',
          ),
        if (syncingCount > 0)
          _statusBadge(
            context,
            Icons.sync,
            context.info,
            '${l.lwSyncBadgeSyncing}: $syncingCount',
          ),
        if (errorCount > 0)
          _statusBadge(
            context,
            Icons.error,
            context.negative,
            '${l.lwSyncBadgeError}: $errorCount',
          ),
        if (reconnectCount > 0)
          _statusBadge(
            context,
            Icons.link_off,
            context.warning,
            '${l.lwSyncBadgeReconnect}: $reconnectCount',
          ),
        if (staleCount > 0)
          _statusBadge(
            context,
            Icons.schedule,
            context.warning,
            '${l.lwSyncBadgeStale}: $staleCount',
          ),
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
    BuildContext context,
    IconData icon,
    Color color,
    String label,
  ) {
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
    return LayoutBuilder(
      builder: (ctx, c) {
        final isNarrow = c.maxWidth < 420;
        return _buildSyncRowBody(context, inst, isNarrow);
      },
    );
  }

  Widget _buildSyncRowBody(
    BuildContext context,
    Map<String, dynamic> inst,
    bool isNarrow,
  ) {
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
                        icon: Icon(
                          Icons.link,
                          color: context.warning,
                          size: 20,
                        ),
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
              if (['error', 'failed', 'setup_required'].contains(status))
                IconButton(
                  icon: Icon(Icons.refresh, color: context.info, size: 20),
                  // Retry THIS institution, not a global sync-all.
                  onPressed: widget.onRetrySingle != null
                      ? () => widget.onRetrySingle!(inst['id'].toString())
                      : widget.onRetrySync,
                  tooltip: l.lwSyncRetrySync,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  color: context.negative,
                  size: 20,
                ),
                onPressed: () => widget.onDelete?.call(inst['id']),
                tooltip: l.lwSyncDeleteInstitution,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
              ),
              // Rare recovery action, so it lives behind a kebab rather than
              // adding a fifth always-visible icon to every row. Rendered
              // ONLY for Plaid rows: a manual/CSV institution has no
              // provider feed to re-check at all (the backend 400s), so
              // there is nothing to offer, not merely something to disable.
              if (widget.onFullResync != null && _isPlaid(inst))
                PopupMenuButton<_RowAction>(
                  icon: Icon(
                    Icons.more_vert,
                    color: context.textMuted,
                    size: 20,
                  ),
                  tooltip: l.lwSyncMoreActions,
                  padding: const EdgeInsets.all(6),
                  onSelected: (action) {
                    if (action == _RowAction.fullResync) {
                      _confirmFullResync(context, inst);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<_RowAction>(
                      value: _RowAction.fullResync,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.history,
                            size: 18,
                            color: context.textMuted,
                          ),
                          const SizedBox(width: 12),
                          Flexible(child: Text(l.lwSyncResyncAction)),
                        ],
                      ),
                    ),
                  ],
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
