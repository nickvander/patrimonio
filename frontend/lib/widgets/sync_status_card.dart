import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SyncStatusCard extends StatelessWidget {
  final List<dynamic> syncData;

  const SyncStatusCard({
    Key? key,
    required this.syncData,
  }) : super(key: key);

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
              'Institution Sync Status',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            if (syncData.isEmpty)
              const Center(child: Text('No institutions linked yet.'))
            else
              ...syncData.map((inst) => _buildSyncRow(inst)).toList(),
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
        statusIcon = Icons.check_circle;
        statusColor = Colors.green;
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
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 20),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    inst['name'] ?? 'Unknown',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Text(
                    'Via ${inst['integration_type']} • $lastSyncText',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ],
          ),
          if (status == 'error')
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.teal),
              onPressed: () {
                // TODO: Trigger manual sync
              },
              tooltip: 'Retry Sync',
            ),
        ],
      ),
    );
  }
}
