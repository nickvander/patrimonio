import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'package:intl/intl.dart';

class FxWidget extends StatefulWidget {
  final Map<String, dynamic> latestRate;
  /// Async callback invoked when the user taps the "Refresh now" button.
  /// Dashboard wires it to force-refresh the FX rate (bypassing cache)
  /// and reload the dashboard so the new value flows through every card.
  final Future<void> Function()? onRefresh;

  const FxWidget({super.key, required this.latestRate, this.onRefresh});

  @override
  State<FxWidget> createState() => _FxWidgetState();
}

class _FxWidgetState extends State<FxWidget> {
  final _apiService = ApiService();
  bool _refreshing = false;
  bool _savingManual = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final latestRate = widget.latestRate;
    final rate = latestRate['rate'] ?? 0.0;
    final source = (latestRate['source'] ?? '').toString();
    // API responds with `base`/`target`; older code used `_currency` suffix.
    final base = (latestRate['base'] ?? latestRate['base_currency'] ?? 'USD')
        .toString();
    final target =
        (latestRate['target'] ?? latestRate['target_currency'] ?? 'MXN')
            .toString();

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l.lwFxExchangeRate,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: (_savingManual || _refreshing)
                          ? null
                          : () => _enterRateManually(base, target, rate),
                      icon: _savingManual
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation(context.positive),
                              ),
                            )
                          : const Icon(Icons.edit_outlined, size: 20),
                      tooltip: l.lwFxEnterManually,
                      color: context.textMuted,
                    ),
                    if (widget.onRefresh != null)
                      IconButton(
                        onPressed: (_refreshing || _savingManual)
                            ? null
                            : () async {
                                setState(() => _refreshing = true);
                                try {
                                  await widget.onRefresh!();
                                } finally {
                                  if (mounted) {
                                    setState(() => _refreshing = false);
                                  }
                                }
                              },
                        icon: _refreshing
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor:
                                      AlwaysStoppedAnimation(context.positive),
                                ),
                              )
                            : const Icon(Icons.refresh, size: 20),
                        tooltip: l.lwFxRefreshNow,
                        color: context.textMuted,
                      ),
                  ],
                ),
              ],
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
                          color: context.textMuted,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          rate.toStringAsFixed(4),
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: context.tealAccent,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 1,
                        ),
                      ),
                      if (latestRate['recorded_at'] != null) ...[
                        const SizedBox(height: 12),
                        _buildTimestampBlock(
                            context, latestRate['recorded_at']),
                      ],
                      if (source.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          l.lwFxSource(source),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textFaint,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                LayoutBuilder(builder: (ctx, c) {
                  // Hide the decorative icon below ~340px so the rate column
                  // doesn't fight a fixed 48px sibling on tiny phones.
                  if (MediaQuery.sizeOf(ctx).width < 360) {
                    return const SizedBox.shrink();
                  }
                  return Icon(
                    Icons.currency_exchange,
                    size: 48,
                    color: context.tealAccent,
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Prompt for a user-entered FX override, pre-filled with the current rate,
  /// POST it (source='manual'), then trigger the dashboard refresh so the new
  /// value flows through every MXN-converted figure.
  Future<void> _enterRateManually(
    String base,
    String target,
    dynamic currentRate,
  ) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(
      text: (currentRate is num && currentRate > 0)
          ? currentRate.toStringAsFixed(4)
          : '',
    );

    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l.lwFxManualDialogTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.lwFxManualDialogHint(base, target),
                  style: TextStyle(color: context.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: '$base / $target',
                    hintText: '0.0000',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: Text(l.actionSave),
            ),
          ],
        );
      },
    );

    if (entered == null) return;
    final parsed = double.tryParse(entered.trim());
    if (parsed == null || parsed <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.lwFxManualInvalid)),
      );
      return;
    }

    setState(() => _savingManual = true);
    try {
      await _apiService.postManualExchangeRate(
        base: base,
        target: target,
        rate: parsed,
      );
      if (widget.onRefresh != null) {
        await widget.onRefresh!();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.lwFxManualSaved)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.lwFxManualFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _savingManual = false);
    }
  }

  Widget _buildTimestampBlock(BuildContext context, dynamic recordedAt) {
    final l = AppLocalizations.of(context);
    final parsed = DateTime.tryParse(recordedAt.toString());
    if (parsed == null) {
      return Text(
        l.lwFxUpdatedUnknown,
        style: TextStyle(fontSize: 11, color: context.textMuted),
      );
    }
    final local = parsed.toLocal();
    final isStale = DateTime.now().difference(local).inHours > 24;
    final fullStamp = DateFormat('MMM d, y · h:mm a').format(local);
    final tz = _shortTimezone(local);
    final age = _humanAge(context, local);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isStale ? Icons.warning_amber_rounded : Icons.schedule,
              size: 13,
              color: isStale ? context.warning : context.textSubtle,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '$fullStamp $tz',
                style: TextStyle(
                  fontSize: 11,
                  color: isStale ? context.warning : context.textMuted,
                  fontWeight: isStale ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          isStale ? l.lwFxStalePrefix(age) : age,
          style: TextStyle(
            fontSize: 10,
            color: isStale ? context.warning : context.textFaint,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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

  String _humanAge(BuildContext context, DateTime local) {
    final l = AppLocalizations.of(context);
    final diff = DateTime.now().difference(local);
    if (diff.inMinutes < 1) return l.lwFxUpdatedJustNow;
    if (diff.inHours < 1) return l.lwFxUpdatedMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l.lwFxUpdatedHoursAgo(diff.inHours);
    return l.lwFxUpdatedDaysAgo(diff.inDays);
  }
}
