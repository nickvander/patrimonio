import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SyncStatusCard extends StatelessWidget {
  final List<dynamic> syncData;
  final VoidCallback? onRetrySync;
  final Function(String id)? onReconnect;
  final Function(String id)? onDelete;

  const SyncStatusCard({
    super.key,
    required this.syncData,
    this.onRetrySync,
    this.onReconnect,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'INSTITUTIONS',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white54,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 24),
            if (syncData.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    const Icon(Icons.account_balance_outlined,
                        size: 32, color: Colors.white24),
                    const SizedBox(height: 8),
                    const Text(
                      'No institutions linked yet',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Use the buttons below to connect a bank, import a\nstatement, or add a manual account.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Icon(Icons.arrow_downward,
                        size: 18, color: Colors.white24),
                  ],
                ),
              )
            else
              ...syncData.map((inst) => _buildSyncRow(inst)),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncRow(Map<String, dynamic> inst) {
    return LayoutBuilder(builder: (ctx, c) {
      final isNarrow = c.maxWidth < 420;
      return _buildSyncRowBody(inst, isNarrow);
    });
  }

  Widget _buildSyncRowBody(Map<String, dynamic> inst, bool isNarrow) {
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

    String lastSyncText = 'Never';
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
                        inst['name'] ?? 'Unknown',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      Text(
                        _statusDetail(inst, status, lastSyncText),
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
                        const Padding(
                          padding: EdgeInsets.only(top: 4.0),
                          child: Text(
                            'Sync failed. Reason unknown — try Retry or Reconnect.',
                            style: TextStyle(
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
                        tooltip: 'Reconnect',
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                      )
                    : TextButton.icon(
                        onPressed: () => onReconnect?.call(inst['id']),
                        icon: const Icon(Icons.link, size: 16),
                        label: const Text('Reconnect'),
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
                  tooltip: 'Retry sync',
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Colors.redAccent, size: 20),
                onPressed: () => onDelete?.call(inst['id']),
                tooltip: 'Delete institution',
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
    Map<String, dynamic> inst,
    String status,
    String lastSyncText,
  ) {
    final source = 'Via ${inst['integration_type']}';
    switch (status) {
      case 'syncing':
        return '$source • Syncing now';
      case 'setup_required':
        return '$source • Setup required before sync';
      case 'reconnect_required':
        return '$source • Reconnect required';
      case 'pending':
        return '$source • Waiting for first sync';
      case 'manual':
        return '$source • Manual/offline source';
      default:
        bool isStale = false;
        if (inst['last_synced_at'] != null) {
          final dt = DateTime.parse(inst['last_synced_at']);
          isStale = DateTime.now().difference(dt).inHours > 24;
        }
        return '$source • $lastSyncText${isStale ? " (Stale)" : ""}';
    }
  }
}
