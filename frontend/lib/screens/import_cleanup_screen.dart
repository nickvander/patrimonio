import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/menus.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/theme_colors.dart';

/// Manage / undo imports. Two paths:
///  1. Recent imports — tagged batches (future imports), each undoable.
///  2. Clean up by account + date range — for PAST imports that predate
///     batch tagging (no batch id), or any bulk removal.
class ImportCleanupScreen extends StatefulWidget {
  const ImportCleanupScreen({
    super.key,
    this.fetchBatchesOverride,
    this.fetchOverviewOverride,
    this.fetchContinuityOverride,
    this.fetchDismissedGapsOverride,
  });

  /// Test seams (same pattern as RebalancingCard): replace the four reads
  /// `_load` issues so widget tests can render batch / statement-coverage
  /// fixtures without network I/O. Production callers never set them.
  final Future<List<dynamic>> Function()? fetchBatchesOverride;
  final Future<Map<String, dynamic>> Function()? fetchOverviewOverride;
  final Future<List<dynamic>> Function()? fetchContinuityOverride;
  final Future<dynamic> Function()? fetchDismissedGapsOverride;

  @override
  State<ImportCleanupScreen> createState() => _ImportCleanupScreenState();
}

class _ImportCleanupScreenState extends State<ImportCleanupScreen> {
  final ApiService _api = ApiService();
  List<dynamic> _batches = [];
  List<dynamic> _accounts = [];
  // Per-account statement-continuity status (gaps across the whole imported
  // history). Each: {account_name, institution_name, statement_count,
  // warnings[]}.
  List<dynamic> _continuity = [];
  // Gaps the user has acknowledged as unobtainable (e.g. a statement they can
  // no longer download). Keyed "account|from_file→to_file"; persisted so they
  // stop showing as warnings. Loaded from a user setting.
  Set<String> _dismissedGaps = {};
  bool _loading = true;

  /// Load failure, or null when the last load succeeded. Kept separate from
  /// "loaded and empty": swallowing the error left the screen rendering
  /// [AppLocalizations.impNoRecentImports] — telling the user their imports
  /// don't exist when the truth is we couldn't ask.
  String? _error;

  // Bulk form state.
  String? _bulkAccountId;
  DateTime? _from;
  DateTime? _to;
  bool _importedOnly = true;
  int? _previewCount;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final batches =
          await (widget.fetchBatchesOverride?.call() ??
              _api.getImportBatches());
      final overview =
          await (widget.fetchOverviewOverride?.call() ??
              _api.getDashboardOverview());
      final continuity =
          await (widget.fetchContinuityOverride?.call() ??
              _api.getImportContinuity());
      final dismissed =
          await (widget.fetchDismissedGapsOverride?.call() ??
              _api.getSetting('dismissed_continuity_gaps'));
      if (!mounted) return;
      setState(() {
        _batches = batches;
        _continuity = continuity;
        _dismissedGaps = dismissed is List
            ? dismissed.map((e) => e.toString()).toSet()
            : {};
        _accounts = (overview['accounts'] as List<dynamic>?) ?? [];
        _bulkAccountId ??= _accounts.isNotEmpty
            ? _accounts.first['id']?.toString()
            : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _undo(Map batch, AppLocalizations l) async {
    final count = (batch['txn_count'] as num?)?.toInt() ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.impUndoImport),
        content: Text(l.impUndoImportConfirm(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.impDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final deleted = await _api.undoImportBatch(batch['batch_id'].toString());
      _toast(l.impDeletedN(deleted));
      await _load();
    } catch (e) {
      _toast(e.toString());
    }
  }

  Future<void> _previewBulk(AppLocalizations l) async {
    if (_bulkAccountId == null || _from == null || _to == null) {
      _toast(l.impCleanupFillAll);
      return;
    }
    setState(() => _busy = true);
    try {
      final count = await _api.bulkDeleteTransactions(
        accountId: _bulkAccountId!,
        dateFrom: _fmtDate(_from!),
        dateTo: _fmtDate(_to!),
        importedOnly: _importedOnly,
        dryRun: true,
      );
      if (!mounted) return;
      setState(() => _previewCount = count);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runBulk(AppLocalizations l) async {
    final count = _previewCount ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.impBulkDelete),
        content: Text(l.impUndoImportConfirm(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.impDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final deleted = await _api.bulkDeleteTransactions(
        accountId: _bulkAccountId!,
        dateFrom: _fmtDate(_from!),
        dateTo: _fmtDate(_to!),
        importedOnly: _importedOnly,
        dryRun: false,
      );
      _toast(l.impDeletedN(deleted));
      setState(() => _previewCount = null);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final es = Localizations.localeOf(context).languageCode == 'es';
    return Scaffold(
      appBar: AppBar(title: Text(l.impCleanupTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorState(l)
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  l.impRecentImports,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                if (_batches.isEmpty)
                  Text(
                    l.impNoRecentImports,
                    style: TextStyle(color: context.textSubtle),
                  )
                else
                  ..._batches.map((b) => _batchCard(b as Map, l)),
                if (_continuity.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  Text(
                    es
                        ? 'Cobertura de estados de cuenta'
                        : 'Statement coverage',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    es
                        ? 'Revisa si falta algún estado de cuenta (saltos en el saldo entre meses).'
                        : 'Flags likely-missing statements — a balance jump between sequential months.',
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                  ),
                  const SizedBox(height: 12),
                  ..._continuity.map((c) => _coverageCard(c as Map, es, l)),
                ],
                const SizedBox(height: 32),
                Text(
                  l.impBulkDelete,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l.impBulkDeleteHint,
                  style: TextStyle(fontSize: 12, color: context.textSubtle),
                ),
                const SizedBox(height: 12),
                _bulkForm(l),
              ],
            ),
    );
  }

  /// House load-failure state (same shape as `account_transactions_screen` /
  /// `tax_planning_screen`): the error, not the empty state, so a failed load
  /// never reads as "you have no imports".
  Widget _errorState(AppLocalizations l) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: context.negative),
            const SizedBox(height: 16),
            Text(l.impLoadError(_error!), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: Text(l.impRetry)),
          ],
        ),
      ),
    );
  }

  String _gapKey(String account, Map gap) =>
      '$account|${gap['from_file'] ?? ''}→${gap['to_file'] ?? ''}';

  Future<void> _dismissGap(String key) async {
    final previous = _dismissedGaps;
    setState(() => _dismissedGaps = {..._dismissedGaps, key});
    try {
      await _api.putSetting(
        'dismissed_continuity_gaps',
        _dismissedGaps.toList(),
      );
    } catch (_) {
      // Roll back rather than leave the gap hidden locally: a dismissal that
      // didn't persist means the "you're missing February" warning silently
      // reappears next session, which reads as the app being flaky.
      if (!mounted) return;
      setState(() => _dismissedGaps = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).dashSettingSaveFailed),
        ),
      );
    }
  }

  Widget _coverageCard(Map c, bool es, AppLocalizations l) {
    final name = (c['account_name'] ?? '').toString();
    final inst = c['institution_name']?.toString();
    final title = (inst != null && inst.isNotEmpty) ? '$inst · $name' : name;
    final count = (c['statement_count'] as num?)?.toInt() ?? 0;
    String money(Object? raw) {
      final v = double.tryParse((raw ?? '').toString());
      return v == null
          ? (raw ?? '').toString()
          : formatCurrencyAmount(v, 'MXN');
    }

    String line(Map e) => l.impContinuityGap(
      (e['from_file'] ?? '').toString(),
      money(e['from_balance']),
      (e['from_date'] ?? '').toString(),
      (e['to_file'] ?? '').toString(),
      money(e['to_balance']),
      (e['to_date'] ?? '').toString(),
      money(e['diff']),
    );

    final allGaps = ((c['warnings'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final gaps = allGaps
        .where((g) => !_dismissedGaps.contains(_gapKey(name, g)))
        .toList();
    final dismissedHere = allGaps.length - gaps.length;
    final ok = gaps.isEmpty;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                  size: 18,
                  color: ok ? context.positive : context.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              ok
                  ? '$count ${es ? "estados de cuenta · continuo" : "statements · continuous"}'
                        '${dismissedHere > 0 ? ' · ${es ? "$dismissedHere ignorado(s)" : "$dismissedHere dismissed"}' : ''}'
                  : '$count ${es ? "estados de cuenta" : "statements"} · ${gaps.length} ${es ? "posible(s) hueco(s)" : "possible gap(s)"}',
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            if (!ok) ...[
              const SizedBox(height: 8),
              for (final g in gaps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '• ${line(g)}',
                          style: const TextStyle(fontSize: 12.5, height: 1.35),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _dismissGap(_gapKey(name, g)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 32),
                          foregroundColor: context.textSubtle,
                        ),
                        child: Text(
                          es ? 'Ignorar' : 'Dismiss',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _batchCard(Map b, AppLocalizations l) {
    final files = (b['files'] as List?)?.cast<dynamic>() ?? const [];
    final fileLabel = files.isEmpty
        ? ''
        : (files.length <= 2
              ? files.join(', ')
              : '${files.take(2).join(', ')} +${files.length - 2}');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          '${b['account_name']} · ${(b['txn_count'] as num?)?.toInt() ?? 0} ${l.impTransactionsLabel}',
        ),
        subtitle: Text(
          '${b['from_date']} → ${b['to_date']}'
          '${fileLabel.isNotEmpty ? '\n$fileLabel' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        isThreeLine: fileLabel.isNotEmpty,
        trailing: TextButton.icon(
          onPressed: () => _undo(b, l),
          icon: Icon(Icons.undo, size: 18, color: context.negative),
          label: Text(l.impUndo, style: TextStyle(color: context.negative)),
        ),
      ),
    );
  }

  Widget _bulkForm(AppLocalizations l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _bulkAccountId,
          dropdownColor: houseDropdownColor(context),
          borderRadius: kMenuRadius,
          decoration: InputDecoration(
            labelText: l.impAssignToAccount,
            border: const OutlineInputBorder(),
          ),
          items: _accounts.map((a) {
            final cur = (a['currency'] as String? ?? '').toUpperCase();
            // Name rendered mask-aware so a trailing "••1234" survives
            // truncation; the (CUR) suffix stays outside the shrinking region.
            return DropdownMenuItem<String>(
              value: a['id']?.toString(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: maskAwareNameText(
                      '${a['institution_name']} - ${a['name']}',
                      const TextStyle(),
                    ),
                  ),
                  Text(' ($cur)'),
                ],
              ),
            );
          }).toList(),
          onChanged: (v) => setState(() {
            _bulkAccountId = v;
            _previewCount = null;
          }),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _dateField(l.impFrom, _from, (d) => _from = d)),
            const SizedBox(width: 12),
            Expanded(child: _dateField(l.impTo, _to, (d) => _to = d)),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.impOnlyImported),
          value: _importedOnly,
          onChanged: (v) => setState(() {
            _importedOnly = v;
            _previewCount = null;
          }),
        ),
        const SizedBox(height: 8),
        if (_previewCount == null)
          OutlinedButton(
            onPressed: _busy ? null : () => _previewBulk(l),
            child: Text(l.impPreview),
          )
        else ...[
          Text(
            l.impWillDelete(_previewCount!),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: context.negative,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: (_busy || _previewCount == 0) ? null : () => _runBulk(l),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(l.impDelete),
          ),
        ],
      ],
    );
  }

  Widget _dateField(
    String label,
    DateTime? value,
    void Function(DateTime) set,
  ) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime.now().add(const Duration(days: 1)),
        );
        if (picked != null) {
          setState(() {
            set(picked);
            _previewCount = null;
          });
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        child: Text(value == null ? '—' : _fmtDate(value)),
      ),
    );
  }
}
