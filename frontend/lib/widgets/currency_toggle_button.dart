import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

/// Compact reporting-currency pill. Replaces the dual icon-only /
/// labelled-button compound that lived inline in the AppBar — the
/// pill is the same shape regardless of breakpoint so the chrome on
/// the right side of the AppBar stays even.
class CurrencyToggleButton extends StatelessWidget {
  final String targetCurrency;
  final VoidCallback onSwap;

  const CurrencyToggleButton({
    super.key,
    required this.targetCurrency,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final active = targetCurrency == 'MXN';
    final accent = active ? context.positive : context.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: AppLocalizations.of(
          context,
        ).currencyToggleTooltip(targetCurrency),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onSwap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.accentBorder(accent)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.currency_exchange, size: 14, color: accent),
                const SizedBox(width: 6),
                Text(
                  targetCurrency,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
