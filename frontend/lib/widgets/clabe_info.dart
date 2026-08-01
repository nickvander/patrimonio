import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

/// A small card showing an account's statement-derived identity — the holder
/// name and the 18-digit CLABE — with a one-tap copy button for the CLABE
/// (the number people paste to receive a transfer). Reused by the add-account
/// dialog (at import time) and the account view, so both look identical.
class ClabeInfoCard extends StatelessWidget {
  final String clabe;
  final String? holder;

  const ClabeInfoCard({super.key, required this.clabe, this.holder});

  /// CLABE grouped in 4s for readability: 638180 0101 8002 0790 → spaced.
  String get _pretty {
    final digits = clabe.replaceAll(RegExp(r'\D'), '');
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.tint(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (holder != null && holder!.trim().isNotEmpty) ...[
            Text(
              holder!.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CLABE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: context.textSubtle,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _pretty,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: l.dlgCopyClabe,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.copy_outlined,
                  size: 18,
                  color: context.tealAccent,
                ),
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: clabe.replaceAll(RegExp(r'\D'), '')),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l.dlgClabeCopied),
                      duration: const Duration(milliseconds: 1500),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
