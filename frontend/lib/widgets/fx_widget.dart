import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class FxWidget extends StatelessWidget {
  final Map<String, dynamic> latestRate;

  const FxWidget({super.key, required this.latestRate});

  @override
  Widget build(BuildContext context) {
    final rate = latestRate['rate'] ?? 0.0;
    final source = (latestRate['source'] ?? '').toString();
    final base = (latestRate['base_currency'] ?? 'USD').toString();
    final target = (latestRate['target_currency'] ?? 'MXN').toString();

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Exchange Rate',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$base / $target',
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        rate.toStringAsFixed(4),
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Colors.tealAccent,
                        ),
                      ),
                      if (latestRate['recorded_at'] != null) ...[
                        const SizedBox(height: 12),
                        _buildTimestampBlock(latestRate['recorded_at']),
                      ],
                      if (source.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Source: $source',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(
                  Icons.currency_exchange,
                  size: 48,
                  color: Colors.teal,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimestampBlock(dynamic recordedAt) {
    final parsed = DateTime.tryParse(recordedAt.toString());
    if (parsed == null) {
      return const Text(
        'Updated: unknown',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      );
    }
    final local = parsed.toLocal();
    final isStale = DateTime.now().difference(local).inHours > 24;
    final fullStamp = DateFormat('MMM d, y · h:mm a').format(local);
    final tz = _shortTimezone(local);
    final age = _humanAge(local);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isStale ? Icons.warning_amber_rounded : Icons.schedule,
              size: 13,
              color: isStale ? Colors.orangeAccent : Colors.white54,
            ),
            const SizedBox(width: 4),
            Text(
              '$fullStamp $tz',
              style: TextStyle(
                fontSize: 11,
                color: isStale ? Colors.orangeAccent : Colors.white70,
                fontWeight: isStale ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          isStale ? 'Stale · $age' : age,
          style: TextStyle(
            fontSize: 10,
            color: isStale ? Colors.orangeAccent.shade100 : Colors.white38,
          ),
        ),
      ],
    );
  }

  /// Best-effort timezone label. Falls back to UTC offset when the OS name
  /// is empty or returns the full IANA name (which is too long on web).
  String _shortTimezone(DateTime local) {
    final name = local.timeZoneName;
    final offsetMin = local.timeZoneOffset.inMinutes;
    final sign = offsetMin >= 0 ? '+' : '-';
    final h = (offsetMin.abs() ~/ 60).toString().padLeft(2, '0');
    final m = (offsetMin.abs() % 60).toString().padLeft(2, '0');
    final offset = 'UTC$sign$h:$m';

    if (name.isEmpty) return '($offset)';
    // Browser-supplied IANA names can be 20+ chars; abbreviate when long.
    if (name.length > 5) return '($offset)';
    return '$name ($offset)';
  }

  String _humanAge(DateTime local) {
    final diff = DateTime.now().difference(local);
    if (diff.inMinutes < 1) return 'Updated just now';
    if (diff.inHours < 1) return 'Updated ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Updated ${diff.inHours}h ago';
    final days = diff.inDays;
    return 'Updated $days day${days == 1 ? '' : 's'} ago';
  }
}
