import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';

/// Sticky banner shown above the dashboard body whenever one or more
/// institutions are in `error` or `reconnect_required` state. Toast
/// snackbars disappear too quickly for these conditions — a sticky
/// pill keeps the issue in front of the user until they act on it.
class SyncErrorBanner extends StatelessWidget {
  final List<dynamic> syncData;
  final VoidCallback? onJumpToManagement;
  final Future<void> Function(String institutionId)? onReconnect;

  const SyncErrorBanner({
    super.key,
    required this.syncData,
    this.onJumpToManagement,
    this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final problems = syncData.where((raw) {
      if (raw is! Map) return false;
      final status = raw['sync_status']?.toString();
      return status == 'error' || status == 'reconnect_required';
    }).toList();

    if (problems.isEmpty) return const SizedBox.shrink();

    final reconnectOnly = problems
        .where((p) => p['sync_status'] == 'reconnect_required')
        .toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Colors.orangeAccent.withValues(alpha: 0.5)),
      ),
      child: LayoutBuilder(builder: (ctx, c) {
        final isNarrow = c.maxWidth < 560;
        final names = problems
            .map((p) => (p['name'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toList();
        final summary = problems.length == 1
            ? '${names.first} needs attention'
            : '${problems.length} institutions need attention';

        final detail = names.length == 1
            ? names.first
            : names.length <= 3
                ? names.join(' · ')
                : '${names.take(2).join(' · ')} +${names.length - 2}';

        final actionRow = Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (reconnectOnly.length == 1 && onReconnect != null)
              TextButton.icon(
                onPressed: () =>
                    onReconnect!(reconnectOnly.first['id'].toString()),
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Reconnect'),
              ),
            TextButton.icon(
              onPressed: onJumpToManagement,
              icon: const Icon(Icons.settings, size: 16),
              label: const Text('Open management'),
            ),
          ],
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.orangeAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                style: TextStyle(color: context.textMuted, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actionRow,
            ],
          );
        }
        return Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.orangeAccent, size: 18),
            const SizedBox(width: 8),
            Text(
              summary,
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                detail,
                style: TextStyle(color: context.textMuted, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            actionRow,
          ],
        );
      }),
    );
  }
}
