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
              const Center(child: Text('No institutions linked yet.'))
            else
              ...syncData.map((inst) => _buildSyncRow(inst)),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncRow(Map<String, dynamic> inst) {
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
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              if (status == 'reconnect_required')
                TextButton.icon(
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
                  icon: const Icon(Icons.refresh, color: Colors.teal),
                  onPressed: onRetrySync,
                  tooltip: 'Retry sync',
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                onPressed: () => onDelete?.call(inst['id']),
                tooltip: 'Delete institution',
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
