import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One-time display of recovery codes. Shown after bootstrap and when
/// the user regenerates codes from the Security page. The dialog is
/// non-dismissible until the user explicitly clicks "I've saved them"
/// — there is no second chance to see these codes.
class RecoveryCodesDialog extends StatefulWidget {
  final List<String> codes;
  const RecoveryCodesDialog({super.key, required this.codes});

  @override
  State<RecoveryCodesDialog> createState() => _RecoveryCodesDialogState();
}

class _RecoveryCodesDialogState extends State<RecoveryCodesDialog> {
  bool _confirmed = false;
  bool _copied = false;

  String get _joined => widget.codes.join('\n');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _joined));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.lock_outline, color: Color(0xFFFFB300)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Save your recovery codes',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: scheme.error),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'These codes will NOT be shown again. Each is single-use; '
                      'use one if you lose your password.',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final code in widget.codes)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(
                        code,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _copy,
                  icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                  label: Text(_copied ? 'Copied' : 'Copy all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmed,
              onChanged: (v) => setState(() => _confirmed = v ?? false),
              title: const Text(
                "I've saved these codes somewhere safe",
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _confirmed ? () => Navigator.of(context).pop() : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
