import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/preferences.dart';
import '../utils/theme_colors.dart';

/// "What changed since your last visit" banner. Pinned above
/// NetWorthCard on the Overview tab when the server has anything to
/// report (at least one new transaction, a non-trivial balance move,
/// or a new sync error since the prior login). Dismissible — the
/// dismiss state is keyed on `previous_login_at` so dismissing it
/// doesn't suppress the banner for future sessions.
class SinceLastLoginBanner extends StatefulWidget {
  /// Raw payload from `GET /api/dashboard/since-last-login`. Null when
  /// the server says there's no anchor yet (first-ever login).
  final Map<String, dynamic>? summary;
  /// Reporting currency formatter — so the "+$1,234.56" amount matches
  /// the rest of the dashboard.
  final NumberFormat currencyFormat;
  /// Conversion factor for USD-stored deltas (1.0 for USD reporting,
  /// USD/MXN rate when reporting in MXN).
  final double conversionFactor;
  /// Tapping the "View transactions" CTA jumps to the Transactions
  /// tab. Receives the anchor (previous-login) date so the dashboard
  /// can seed a date filter to "since X" — the banner stops being a
  /// vague hop and becomes a real drill-in.
  final void Function(DateTime anchor)? onJumpToTransactions;
  /// Tapping the "Open management" CTA jumps to the Management tab (used
  /// to surface a sync_errors call-out next to the institution row).
  final VoidCallback? onJumpToManagement;

  const SinceLastLoginBanner({
    super.key,
    required this.summary,
    required this.currencyFormat,
    required this.conversionFactor,
    this.onJumpToTransactions,
    this.onJumpToManagement,
  });

  @override
  State<SinceLastLoginBanner> createState() => _SinceLastLoginBannerState();
}

class _SinceLastLoginBannerState extends State<SinceLastLoginBanner> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _refreshDismissed();
  }

  @override
  void didUpdateWidget(SinceLastLoginBanner old) {
    super.didUpdateWidget(old);
    // If the summary changes (e.g. user signed out and back in) reset
    // the dismiss check against the new anchor.
    if (widget.summary?['previous_login_at'] !=
        old.summary?['previous_login_at']) {
      _refreshDismissed();
    }
  }

  void _refreshDismissed() {
    final anchor = widget.summary?['previous_login_at']?.toString();
    if (anchor == null) {
      setState(() => _dismissed = false);
      return;
    }
    setState(() =>
        _dismissed = Preferences.getSinceLastLoginDismissedFor(anchor));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    if (s == null || _dismissed) return const SizedBox.shrink();

    final newTx = (s['new_transactions'] as num?)?.toInt() ?? 0;
    final largestMove = s['largest_move'] as Map?;
    final syncErrors =
        ((s['sync_errors'] as List?) ?? const []).cast<String>();
    final anchorIso = s['previous_login_at']?.toString();
    final anchor = anchorIso != null ? DateTime.tryParse(anchorIso) : null;

    // Suppress the banner entirely when there's nothing to say — keeps
    // it out of the way on a "just checked in five minutes ago" reload.
    final hasContent = newTx > 0 ||
        (largestMove != null) ||
        syncErrors.isNotEmpty;
    if (!hasContent) return const SizedBox.shrink();

    // Compose a short headline.
    final pieces = <String>[];
    if (newTx > 0) {
      pieces.add('$newTx new transaction${newTx == 1 ? '' : 's'}');
    }
    if (largestMove != null) {
      final delta =
          ((largestMove['delta_usd'] as num?)?.toDouble() ?? 0.0) *
              widget.conversionFactor;
      final name = (largestMove['account_name'] ?? '').toString();
      final sign = delta >= 0 ? '+' : '−';
      pieces.add(
        '$sign${widget.currencyFormat.format(delta.abs())} on $name',
      );
    }
    if (syncErrors.isNotEmpty) {
      pieces.add(
        '${syncErrors.length} sync error${syncErrors.length == 1 ? '' : 's'}',
      );
    }
    final summary = pieces.join(' · ');

    final subtitle = anchor == null
        ? 'Since your last visit'
        : 'Since ${DateFormat('MMM d, h:mm a').format(anchor.toLocal())}';

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: context.accentSoft(context.positive),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(context.positive)),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome,
              size: 18, color: context.positive),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: context.textSubtle,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (newTx > 0 && widget.onJumpToTransactions != null && anchor != null)
            TextButton(
              onPressed: () => widget.onJumpToTransactions!(anchor),
              child: const Text('View'),
            ),
          if (syncErrors.isNotEmpty && widget.onJumpToManagement != null)
            TextButton(
              onPressed: widget.onJumpToManagement,
              child: const Text('Fix'),
            ),
          IconButton(
            tooltip: 'Dismiss',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: () {
              if (anchorIso != null) {
                Preferences.dismissSinceLastLoginFor(anchorIso);
              }
              setState(() => _dismissed = true);
            },
          ),
        ],
      ),
    );
  }
}
