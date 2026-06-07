import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../utils/supported_banks.dart';
import '../utils/theme_colors.dart';
import '../utils/currency.dart';
import '../utils/category.dart';
import '../widgets/add_account_dialog.dart';
import 'import_cleanup_screen.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../services/file_drop_web.dart';
import '../l10n/app_localizations.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final ApiService _apiService = ApiService();
  bool _isUploading = false;
  // Multi-file support: a single upload can include many statements
  // (e.g. all 12 monthly Banamex PDFs at once). Parsed transactions
  // from every file get concatenated into _previewTransactions for
  // the same downstream review-and-confirm flow.
  List<PlatformFile> _selectedFiles = [];
  List<dynamic>? _previewTransactions;
  Set<int> _selectedIndices = {};
  // Preview rows already present in the chosen account (by the backend's
  // dedup signature). Flagged + auto-deselected so the user doesn't
  // re-import them; recomputed whenever the account changes.
  Set<int> _duplicateIndices = {};
  // source_file → its row indices, computed ONCE when the preview loads.
  // Avoids re-grouping all rows on every rebuild (the per-file chips read
  // this), which was a chunk of the lag with 1000+ transactions.
  Map<String, List<int>> _fileGroups = {};
  List<dynamic>? _accounts;
  String? _selectedAccountId;
  // When one statement bundles more than one account (Banamex's primary
  // MiCuenta + a Pagaré/Ahorro section), the parser tags the secondary rows
  // with `account_label`. These are the distinct secondary labels seen in
  // the preview and the destination account picked for each — so the savings
  // section is routed to its own account instead of being dropped.
  List<String> _secondaryLabels = [];
  final Map<String, String?> _secondaryAccountIds = {};
  // Statement-derived account metadata from the latest parsed statement
  // (suggested name + balance, CLABE, holder). Used to pre-fill the primary
  // account when creating one inline during import.
  Map<String, dynamic>? _accountInfo;
  String? _message;
  /// Whether `_message` represents a failure. Tracked explicitly rather
  /// than sniffing the message text for "failed" — the copy is now
  /// localized, so substring matching on English words is unreliable.
  bool _messageIsError = false;

  bool _requiresPassword = false;
  final TextEditingController _passwordController = TextEditingController();

  /// True while the user is dragging files over the page. Flips the
  /// drop-zone border + shows the "Drop files here" overlay so the
  /// user gets feedback that the page actually accepts the drop.
  bool _isDragging = false;

  /// True between "user picked / dropped files" and "byte-read
  /// completed". The browser's FileReader path reads files
  /// sequentially via `arrayBuffer()`, which can take several
  /// seconds for a batch of PDFs. Without this flag the screen
  /// sits still in its idle state until the read finishes, looking
  /// frozen — so we render a "Reading N files…" status while the
  /// flag is true.
  bool _isReadingFiles = false;
  /// File count the drop handler told us about (only set during a
  /// drop — for picker-initiated reads we don't know the count
  /// until the OS dialog returns).
  int? _readingFileCount;

  /// Per-file upload-parse progress fed by the backend's progress
  /// side-channel — one [ImportFileStatus] per selected file
  /// (waiting → parsing → ok/failed), rendered as a live checklist so a
  /// long batch (12+ PDFs) shows each file resolve with its transaction
  /// count instead of a blank "Processing N files…" wait.
  List<ImportFileStatus> _fileStatuses = [];

  /// Web-only drag-and-drop listener. Null on non-web targets — the
  /// import screen is reachable from the dashboard which itself only
  /// runs on web today, but the null-check keeps the screen safe if
  /// it's ever rendered headlessly (tests, future native build).
  GlobalFileDropListener? _dropListener;

  // Descriptions that should be auto-deselected (informational, not real transactions)
  static const _autoDeselectPatterns = [
    'EXENCION COBRO COMISION',
    'EXENCION COBRO DE COMISION',
    'MANEJO DE CUENTA',
  ];

  @override
  void initState() {
    super.initState();
    _fetchAccounts();
    if (kIsWeb) {
      _dropListener = GlobalFileDropListener(
        onFiles: _handleDroppedFiles,
        onDragState: (active) {
          if (!mounted) return;
          setState(() => _isDragging = active);
        },
        onReadingStart: (count) {
          if (!mounted) return;
          setState(() {
            _isReadingFiles = true;
            _readingFileCount = count;
          });
        },
      );
      _dropListener!.attach();
    }
  }

  @override
  void dispose() {
    _dropListener?.detach();
    _passwordController.dispose();
    super.dispose();
  }

  /// Append dropped files to the existing selection (same shape as
  /// "Add more files" via the picker). If a preview was already
  /// rendered for a previous batch, throw it out — the new files
  /// need their own parse pass. Drops are silently ignored while
  /// an upload is in flight to avoid the "files appeared but
  /// weren't sent" confusion.
  void _handleDroppedFiles(List<PlatformFile> files) {
    // Reading phase is finished by the time this fires (the drop
    // listener awaits FileReader before invoking us). Clear the
    // loading flag whether we keep the files or bounce them.
    if (mounted) {
      setState(() {
        _isReadingFiles = false;
        _readingFileCount = null;
      });
    }
    if (files.isEmpty) return;
    if (_isUploading) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).impWaitForUpload),
        ),
      );
      return;
    }
    setState(() {
      _selectedFiles = [..._selectedFiles, ...files];
      _previewTransactions = null;
      _selectedIndices = {};
      _message = null;
      _requiresPassword = false;
      _passwordController.clear();
    });
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          files.length == 1
              ? l.impAddedFileFromDrop
              : l.impAddedFilesFromDrop(files.length),
        ),
      ),
    );
  }

  Future<void> _fetchAccounts() async {
    try {
      final overview = await _apiService.getDashboardOverview();
      setState(() {
        final all = overview['accounts'] as List<dynamic>? ?? [];
        // Sort: MXN accounts first (most common import target for Mexico PDFs),
        // then by institution name so the dropdown is predictable.
        all.sort((a, b) {
          final aCur = (a['currency'] as String? ?? '').toUpperCase();
          final bCur = (b['currency'] as String? ?? '').toUpperCase();
          if (aCur == 'MXN' && bCur != 'MXN') return -1;
          if (bCur == 'MXN' && aCur != 'MXN') return 1;
          final aName = '${a['institution_name']} ${a['name']}';
          final bName = '${b['institution_name']} ${b['name']}';
          return aName.compareTo(bName);
        });
        _accounts = all;
        if (_accounts != null && _accounts!.isNotEmpty) {
          _selectedAccountId = _accounts!.first['id'];
        }
      });
    } catch (e) {
      debugPrint('Failed to fetch accounts: $e');
    }
  }

  Future<void> _pickFile() async {
    // file_picker on web reads each file's bytes into memory before
    // resolving (PlatformFile.bytes is populated synchronously from
    // the Future). For a year of monthly PDFs that's a non-trivial
    // wait — flip the reading flag so the UI surfaces "Reading
    // files…" instead of looking frozen on the idle drop zone.
    // We don't know the count yet (OS dialog hasn't returned), so
    // _readingFileCount stays null and the UI falls back to a
    // generic "Reading files…" string.
    setState(() {
      _isReadingFiles = true;
      _readingFileCount = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'pdf'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedFiles = result.files;
          _previewTransactions = null;
          _selectedIndices = {};
          _message = null;
          _requiresPassword = false;
          _passwordController.clear();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isReadingFiles = false;
          _readingFileCount = null;
        });
      }
    }
  }

  void _removeFileAt(int index) {
    setState(() {
      _selectedFiles = List<PlatformFile>.from(_selectedFiles)..removeAt(index);
    });
  }

  /// Initialize selection: select all except auto-deselect patterns
  void _initializeSelection() {
    if (_previewTransactions == null) return;
    _selectedIndices = {};
    final groups = <String, List<int>>{};
    for (int i = 0; i < _previewTransactions!.length; i++) {
      final tx = _previewTransactions![i];
      final desc = (tx['description'] ?? '').toString().toUpperCase();
      final shouldDeselect = _autoDeselectPatterns.any((p) => desc.contains(p));
      if (!shouldDeselect) {
        _selectedIndices.add(i);
      }
      final f = tx['source_file']?.toString();
      if (f != null && f.isNotEmpty) {
        groups.putIfAbsent(f, () => []).add(i);
      }
    }
    _fileGroups = groups;

    // Distinct secondary-account labels (e.g. "Cuenta secundaria") so the UI
    // can offer a destination per bundled account.
    final labels = <String>{};
    for (final tx in _previewTransactions!) {
      final lbl = (tx['account_label'] ?? '').toString();
      if (lbl.isNotEmpty) labels.add(lbl);
    }
    _secondaryLabels = labels.toList()..sort();
    _secondaryAccountIds.removeWhere((k, _) => !labels.contains(k));
  }

  /// Backend caps the multipart body at 100 MB (DefaultBodyLimit in
  /// api/imports.rs). Rather than rejecting a big drop, we auto-split it
  /// into batches that each stay under [_perBatchBytes] (headroom under
  /// the cap for multipart framing) and upload them in sequence. A
  /// single file larger than the hard cap can't be split, so that one
  /// case still surfaces a clear error.
  static const int _maxUploadBytes = 100 * 1024 * 1024;
  static const int _perBatchBytes = 80 * 1024 * 1024;

  Future<void> _uploadFile() async {
    if (_selectedFiles.isEmpty) return;

    final l = AppLocalizations.of(context);
    // The only unrecoverable case: a single file over the hard cap (it
    // can't be batched). Individual statements are ~3-5 MB, so this is
    // rare — but give a precise message instead of a silent 413.
    final tooBig =
        _selectedFiles.where((f) => f.size > _maxUploadBytes).toList();
    if (tooBig.isNotEmpty) {
      final f = tooBig.first;
      final mb = (f.size / (1024 * 1024)).toStringAsFixed(1);
      setState(() {
        _message = l.impFileTooLarge(f.name, mb);
        _messageIsError = true;
      });
      return;
    }

    setState(() {
      _isUploading = true;
      _message = null;
      _duplicateIndices = {};
      _fileStatuses = [
        for (final f in _selectedFiles) ImportFileStatus(f.name, 'waiting'),
      ];
    });

    try {
      final response = await _apiService.uploadStatements(
        _selectedFiles,
        password: _passwordController.text.trim().isEmpty
            ? null
            : _passwordController.text.trim(),
        maxBatchBytes: _perBatchBytes,
        onProgress: ({
          required List<ImportFileStatus> files,
          required int done,
          required int total,
        }) {
          if (!mounted) return;
          setState(() => _fileStatuses = files);
        },
      );

      setState(() {
        _message = response['message'];
        _isUploading = false;

        if (response['status'] == 'password_required') {
          _requiresPassword = true;
          _previewTransactions = null;
          _messageIsError = false;
        } else if (response['status'] == 'success') {
          _previewTransactions = response['transactions'];
          // Statement-derived account metadata (CLABE, holder, suggested
          // name + balance) for pre-filling a new primary account.
          _accountInfo = response['account_info'] is Map<String, dynamic>
              ? response['account_info'] as Map<String, dynamic>
              : null;
          _initializeSelection();
          _messageIsError = false;
        } else {
          _messageIsError = true;
        }
      });

      if (response['status'] == 'success' && _previewTransactions != null) {
        final autoDeselected =
            _previewTransactions!.length - _selectedIndices.length;
        final msg =
            l.impFoundTransactions(response['transactions_count'] as int);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              autoDeselected > 0
                  ? l.impFoundWithAutoDeselected(msg, autoDeselected)
                  : msg,
            ),
          ),
        );
      }
      // Flag rows already imported in the (pre-)selected account.
      await _recheckDuplicates();
    } catch (e) {
      setState(() {
        _message = l.impUploadFailed(e.toString());
        _messageIsError = true;
        _isUploading = false;
      });
    }
  }

  /// Create a destination account inline (for statements from a bank that
  /// isn't linked, e.g. Banamex). Reuses the shared AddAccountDialog,
  /// pre-set to the imported transactions' currency, then auto-selects the
  /// new account so the user can import straight into it.
  ///
  /// [secondaryLabel] routes the new account to a bundled secondary section
  /// instead of the primary destination (null = primary).
  Future<void> _openCreateAccount({String? secondaryLabel}) async {
    final cur = (_previewTransactions?.isNotEmpty ?? false)
        ? (_previewTransactions!.first['currency']?.toString().toUpperCase() ??
            'MXN')
        : 'MXN';
    final existingIds =
        (_accounts ?? const []).map((a) => a['id']).toSet();

    // Suggest a starting balance from this section's movements. Statements
    // like Nu don't print a per-row balance, but the net of a section's rows
    // approximates its balance when the history starts from the account's
    // inception (the common case for a cajita). The dialog clamps negatives
    // and lets the user edit, so a rough suggestion never silently misleads.
    double sectionNet(String? label) {
      double s = 0;
      for (final tx in _previewTransactions ?? const []) {
        final l = (tx['account_label'] ?? '').toString();
        final match = label == null ? l.isEmpty : l == label;
        if (match) s += (tx['amount'] as num?)?.toDouble() ?? 0.0;
      }
      return s;
    }

    // Primary account: prefer the statement's parsed account info — the real
    // portfolio/account balance + name + CLABE — over the cash-net heuristic
    // (which is ~0 for a cetesdirecto statement). Secondary sections (Nu
    // cajitas) keep the per-section net + the cajita label as the name.
    final info = secondaryLabel == null ? _accountInfo : null;
    final infoBalance = (info?['suggested_balance'] as num?)?.toDouble();
    final infoName = info?['suggested_name'] as String?;
    final infoCurrency = (info?['currency'] as String?)?.toUpperCase();

    await showDialog<void>(
      context: context,
      builder: (_) => AddAccountDialog(
        defaultCurrency: infoCurrency ?? cur,
        suggestedBalance: infoBalance ?? sectionNet(secondaryLabel),
        suggestedName: infoName ?? secondaryLabel,
        suggestedClabe: info?['clabe'] as String?,
        suggestedHolder: info?['holder_name'] as String?,
        onAccountCreated: () =>
            _selectNewlyCreatedAccount(existingIds, secondaryLabel),
      ),
    );
  }

  /// After an inline account creation, reload accounts and select the one
  /// that wasn't there before (robust against duplicate names). Fire-and-
  /// forget so it fits AddAccountDialog's VoidCallback. [secondaryLabel]
  /// assigns the new account to that bundled section's slot (null = primary).
  void _selectNewlyCreatedAccount(Set<dynamic> existingIds, String? secondaryLabel) {
    () async {
      await _fetchAccounts();
      if (!mounted) return;
      final created = (_accounts ?? const []).cast<dynamic>().firstWhere(
            (a) => !existingIds.contains(a['id']),
            orElse: () => null,
          );
      if (created != null) {
        final id = created['id']?.toString();
        setState(() {
          if (secondaryLabel == null) {
            _selectedAccountId = id;
          } else {
            _secondaryAccountIds[secondaryLabel] = id;
          }
        });
        if (secondaryLabel == null) _recheckDuplicates();
      }
    }();
  }

  /// Count of currently-selected preview rows belonging to a bundled
  /// secondary-account section.
  int _countForLabel(String label) {
    if (_previewTransactions == null) return 0;
    var n = 0;
    for (final i in _selectedIndices) {
      if ((_previewTransactions![i]['account_label'] ?? '').toString() == label) {
        n++;
      }
    }
    return n;
  }

  /// Destination pickers for the secondary accounts bundled in a statement
  /// (Banamex primary + Pagaré/Ahorro). Each section gets its own account
  /// dropdown + inline-create; unassigned sections are skipped at confirm.
  List<Widget> _buildSecondaryPickers(BuildContext context) {
    final es = Localizations.localeOf(context).languageCode == 'es';
    final accounts = _accounts ?? const [];
    return [
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.info.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              es
                  ? 'Este estado de cuenta incluye otra(s) cuenta(s)'
                  : 'This statement includes additional account(s)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              es
                  ? 'Elige una cuenta destino para cada sección, o crea una nueva. Las secciones sin cuenta no se importarán.'
                  : "Pick a destination account for each section, or create one. Sections left unassigned won't be imported.",
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            for (final label in _secondaryLabels) ...[
              const SizedBox(height: 12),
              Text(
                '$label · ${_countForLabel(label)} ${es ? "movimientos" : "transactions"}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              if (accounts.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _secondaryAccountIds[label],
                  isExpanded: true,
                  hint: Text(es ? 'Elegir cuenta…' : 'Choose account…'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: context.tint(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  items: accounts.map<DropdownMenuItem<String>>((acc) {
                    final cur = (acc['currency'] as String? ?? '').toUpperCase();
                    final lbl = cur.isNotEmpty
                        ? '${acc['institution_name']} - ${acc['name']} ($cur)'
                        : '${acc['institution_name']} - ${acc['name']}';
                    return DropdownMenuItem<String>(
                      value: acc['id'],
                      child: Text(lbl),
                    );
                  }).toList(),
                  onChanged: (val) =>
                      setState(() => _secondaryAccountIds[label] = val),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _openCreateAccount(secondaryLabel: label),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(es ? 'Crear cuenta' : 'Create account'),
                ),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  /// Flag (and auto-deselect) preview rows already imported in the chosen
  /// account. Re-runs whenever the account or preview changes. Best-effort.
  Future<void> _recheckDuplicates() async {
    final acct = _selectedAccountId;
    final txs = _previewTransactions;
    if (acct == null || txs == null || txs.isEmpty) {
      if (_duplicateIndices.isNotEmpty) {
        setState(() => _duplicateIndices = {});
      }
      return;
    }
    final dups = await _apiService.checkImportDuplicates(acct, txs);
    if (!mounted) return;
    setState(() {
      _duplicateIndices = dups;
      // Don't re-import what's already there.
      _selectedIndices = _selectedIndices.difference(dups);
    });
  }

  /// Live multi-PDF progress: a header count plus a checklist with one
  /// row per file (waiting → parsing → ✓ count / skipped).
  Widget _buildUploadProgress(AppLocalizations l) {
    final total =
        _fileStatuses.isEmpty ? _selectedFiles.length : _fileStatuses.length;
    final done = _fileStatuses.where((s) => s.isDone).length;
    return Column(
      children: [
        Text(
          total == 1
              ? l.impProcessingOneFile
              : (done > 0
                  ? l.impProcessingProgress(done, total)
                  : l.impProcessingNFiles(total)),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: context.info,
          ),
        ),
        const SizedBox(height: 12),
        if (_fileStatuses.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 440),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in _fileStatuses) _buildFileRow(l, s),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        // Scanned / photographed statements have no text layer, so the
        // server reads them with OCR — that's the slow step. Call it out so
        // a file sitting on "parsing…" reads as working, not stuck.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.document_scanner_outlined,
                  size: 14, color: context.textFaint),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  l.impOcrHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11.5, color: context.textSubtle, height: 1.3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildFileRow(AppLocalizations l, ImportFileStatus s) {
    final Widget leading;
    final String trailing;
    final Color trailingColor;
    switch (s.status) {
      case 'ok':
        leading = Icon(Icons.check_circle, size: 16, color: context.positive);
        trailing = l.impFileTransactions(s.count);
        trailingColor = context.textSubtle;
        break;
      case 'failed':
        leading = Icon(Icons.error_outline, size: 16, color: context.warning);
        trailing = l.impFileSkipped;
        trailingColor = context.warning;
        break;
      case 'parsing':
        leading = const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        trailing = l.impFileParsing;
        trailingColor = context.textSubtle;
        break;
      default: // waiting
        leading =
            Icon(Icons.schedule_outlined, size: 16, color: context.textFaint);
        trailing = l.impFileWaiting;
        trailingColor = context.textFaint;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: [
          SizedBox(width: 18, child: Center(child: leading)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: context.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          Text(trailing,
              style: TextStyle(fontSize: 12, color: trailingColor)),
        ],
      ),
    );
  }

  Future<void> _confirmImport() async {
    final l = AppLocalizations.of(context);
    if (_previewTransactions == null) return;

    // Group the selected rows by their destination account. The primary
    // section (no account_label) goes to `_selectedAccountId`; each bundled
    // secondary section goes to the account chosen for its label.
    final byAccount = <String, List<dynamic>>{};
    final unassigned = <String>[]; // secondary labels with no account chosen
    for (final i in _selectedIndices) {
      final tx = _previewTransactions![i];
      final label = (tx['account_label'] ?? '').toString();
      final accountId =
          label.isEmpty ? _selectedAccountId : _secondaryAccountIds[label];
      if (accountId == null || accountId.isEmpty) {
        if (label.isEmpty) {
          // Primary section with no account selected — the original guard.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.impSelectAccountFirst,
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          );
          return;
        }
        if (!unassigned.contains(label)) unassigned.add(label);
        continue;
      }
      byAccount.putIfAbsent(accountId, () => []).add(tx);
    }

    if (byAccount.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.impNoTransactionsSelected)),
      );
      return;
    }

    setState(() => _isUploading = true);

    try {
      final messages = <String>[];
      final warnings = <String>[];
      // One confirm call per destination account.
      for (final entry in byAccount.entries) {
        final response =
            await _apiService.confirmImport(entry.key, entry.value);
        if (response['message'] != null) {
          messages.add(response['message'].toString());
        }
        final w = response['warnings'];
        if (w is List) warnings.addAll(w.map((e) => e.toString()));
      }

      if (!mounted) return;

      // Surface likely-missing-statement warnings before leaving the screen.
      if (warnings.isNotEmpty) {
        await _showContinuityWarnings(warnings);
        if (!mounted) return;
      }

      final skippedNote = unassigned.isEmpty
          ? ''
          : (Localizations.localeOf(context).languageCode == 'es'
              ? ' (secciones sin cuenta omitidas: ${unassigned.join(", ")})'
              : ' (skipped unassigned sections: ${unassigned.join(", ")})');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (messages.isEmpty ? l.impImportSuccessful : messages.join(' · ')) +
                skippedNote,
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      setState(() {
        _message = l.impConfirmationFailed(e.toString());
        _messageIsError = true;
        _isUploading = false;
      });
    }
  }

  /// Show the backend's statement-continuity warnings (likely missing
  /// months) in a dialog so the user can go fetch the gap before relying on
  /// the import being complete.
  Future<void> _showContinuityWarnings(List<String> warnings) async {
    final es = Localizations.localeOf(context).languageCode == 'es';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: context.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(es
                  ? 'Posibles estados de cuenta faltantes'
                  : 'Possible missing statements'),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in warnings) ...[
                Text('• $w', style: const TextStyle(fontSize: 13, height: 1.35)),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(es ? 'Entendido' : 'Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.impTitle),
        actions: [
          IconButton(
            tooltip: l.impCleanupTitle,
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ImportCleanupScreen(),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.impUploadHeading,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              l.impUploadSubtitle(supportedMxBanksSentence()),
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            if (_previewTransactions == null)
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  width: double.infinity,
                  padding: const EdgeInsets.all(48),
                  decoration: BoxDecoration(
                    color: (_isUploading || _isReadingFiles)
                        ? context.info.withValues(alpha: 0.06)
                        : _isDragging
                            ? context.positive.withValues(alpha: 0.08)
                            : context.tint(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: (_isUploading || _isReadingFiles)
                          ? context.info
                          : _isDragging
                              ? context.positive
                              : context.hairline,
                      width: 2,
                    ),
                  ),
                  child: Column(
                    children: [
                      // Four states drive the icon area:
                      //   1. Reading  → spinner with the count we got
                      //      from the drop handler (or "…" when we
                      //      came in via the OS file picker — the
                      //      dialog hasn't returned yet). Fills the
                      //      previously-silent gap while the
                      //      FileReader chews through the PDFs.
                      //   2. Uploading → spinner + file count.
                      //      Server-side parsing of 12 monthly Banamex
                      //      PDFs can take 60-120 s.
                      //   3. Dragging  → upload icon, accent green.
                      //   4. Idle      → upload icon, accent green.
                      if (_isUploading || _isReadingFiles)
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                strokeWidth: 4,
                                color: context.info,
                              ),
                              Text(
                                _isReadingFiles
                                    ? (_readingFileCount?.toString() ?? '…')
                                    : '${_selectedFiles.length}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: context.info,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Icon(
                          Icons.upload_file,
                          size: 64,
                          color: context.positive,
                        ),
                      const SizedBox(height: 16),
                      if (_isReadingFiles)
                        Column(
                          children: [
                            Text(
                              _readingFileCount == null
                                  ? l.impReadingFiles
                                  : _readingFileCount == 1
                                      ? l.impReadingOneFile
                                      : l.impReadingNFiles(_readingFileCount!),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: context.info,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l.impReadingHint,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.textSubtle,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                          ],
                        )
                      else if (_isUploading)
                        _buildUploadProgress(l),
                      // Drag / idle helper text — hidden while
                      // uploading OR reading so the status block
                      // above owns the user's attention.
                      if (!_isUploading && !_isReadingFiles && _isDragging)
                        Text(
                          l.impDropToImport,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: context.positive,
                          ),
                        )
                      else if (!_isUploading &&
                          !_isReadingFiles &&
                          kIsWeb &&
                          _selectedFiles.isEmpty)
                        Text(
                          l.impDropHint,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.textSubtle,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      if (!_isUploading &&
                          !_isReadingFiles &&
                          (_isDragging || (kIsWeb && _selectedFiles.isEmpty)))
                        const SizedBox(height: 16),
                      if (!_isUploading &&
                          !_isReadingFiles &&
                          _selectedFiles.isEmpty &&
                          !kIsWeb &&
                          !_isDragging)
                        Text(l.impNoFilesSelected),
                      if (_selectedFiles.isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedFiles.length == 1
                                  ? l.impOneFileSelected
                                  : l.impNFilesSelected(_selectedFiles.length),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 200),
                              child: SingleChildScrollView(
                                child: Column(
                                  children: [
                                    for (var i = 0; i < _selectedFiles.length; i++)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 2),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.insert_drive_file_outlined, size: 16),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                _selectedFiles[i].name,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 13),
                                              ),
                                            ),
                                            Text(
                                              '${(_selectedFiles[i].size / 1024).toStringAsFixed(1)} KB',
                                              style: const TextStyle(
                                                color: Colors.grey,
                                                fontSize: 11,
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.close, size: 16),
                                              tooltip: l.impRemoveFile,
                                              visualDensity: VisualDensity.compact,
                                              onPressed: (_isUploading || _isReadingFiles)
                                                  ? null
                                                  : () => _removeFileAt(i),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: (_isUploading || _isReadingFiles)
                            ? null
                            : _pickFile,
                        icon: Icon(
                          _selectedFiles.isEmpty
                              ? Icons.folder_open_outlined
                              : Icons.add_circle_outline,
                          size: 18,
                        ),
                        label: Text(
                          _selectedFiles.isEmpty
                              ? l.impSelectFiles
                              : l.impAddMoreFiles,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.impAssignToAccount,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  if (_accounts != null)
                    DropdownButtonFormField<String>(
                      initialValue: _selectedAccountId,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: context.tint(0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      items: _accounts!.map((acc) {
                        final cur = (acc['currency'] as String? ?? '').toUpperCase();
                        final label = cur.isNotEmpty
                            ? '${acc['institution_name']} - ${acc['name']} ($cur)'
                            : '${acc['institution_name']} - ${acc['name']}';
                        return DropdownMenuItem<String>(
                          value: acc['id'],
                          child: Text(label),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setState(() => _selectedAccountId = val);
                        _recheckDuplicates();
                      },
                    )
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  // Statements from a bank you haven't linked (e.g. Banamex)
                  // have no destination account yet — let the user make one
                  // inline, pre-set to the statements' currency.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _openCreateAccount,
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l.impCreateAccountForImport),
                    ),
                  ),
                  // Per-section destination pickers when a statement bundles
                  // more than one account (Banamex primary + Pagaré/Ahorro).
                  if (_secondaryLabels.isNotEmpty)
                    ..._buildSecondaryPickers(context),
                  const SizedBox(height: 24),

                  // Header row with title and selection controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          l.impPreviewSelected(_selectedIndices.length,
                              _previewTransactions!.length),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _selectedIndices = Set<int>.from(
                                  List.generate(
                                    _previewTransactions!.length,
                                    (i) => i,
                                  ),
                                );
                              });
                            },
                            child: Text(
                              l.impSelectAll,
                              style: TextStyle(color: context.positive),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _selectedIndices = {};
                              });
                            },
                            child: Text(
                              l.impDeselectAll,
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Per-file filter: one chip per source PDF. Tap to
                  // include/exclude all of that file's rows at once — the
                  // fast way to drop a mis-parsed file. Only shown when the
                  // batch spans more than one file.
                  Builder(builder: (context) {
                    final byFile = _fileGroups;
                    if (byFile.length < 2) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: byFile.entries.map((e) {
                          final allSelected =
                              e.value.every(_selectedIndices.contains);
                          final anySelected =
                              e.value.any(_selectedIndices.contains);
                          return FilterChip(
                            label: Text('${e.key}  (${e.value.length})'),
                            selected: allSelected,
                            showCheckmark: true,
                            onSelected: (_) {
                              setState(() {
                                final s = Set<int>.from(_selectedIndices);
                                // Any part selected → exclude the whole
                                // file; fully excluded → include it.
                                if (anySelected) {
                                  e.value.forEach(s.remove);
                                } else {
                                  s.addAll(e.value);
                                }
                                _selectedIndices = s;
                              });
                            },
                          );
                        }).toList(),
                      ),
                    );
                  }),
                  // Bounded-height, self-scrolling list so only the
                  // visible rows are built. The old shrinkWrap +
                  // NeverScrollable list (inside the page scroll view) built
                  // ALL 1000+ rows on every setState — the main source of
                  // the lag with a big batch.
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.62,
                    child: ListView.builder(
                    itemCount: _previewTransactions!.length,
                    itemBuilder: (context, index) {
                      final tx = _previewTransactions![index];
                      final isSelected = _selectedIndices.contains(index);
                      final desc = (tx['description'] ?? '')
                          .toString()
                          .toUpperCase();
                      final isAutoDeselected = _autoDeselectPatterns.any(
                        (p) => desc.contains(p),
                      );
                      final isDuplicate = _duplicateIndices.contains(index);

                      return Card(
                        color: isSelected
                            ? context.tint(0.05)
                            : Colors.transparent,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(
                            color: isSelected
                                ? context.positive.withValues(alpha: 0.5)
                                : context.hairline,
                            width: 1,
                          ),
                        ),
                        margin: const EdgeInsets.only(bottom: 8.0),
                        child: CheckboxListTile(
                          value: isSelected,
                          activeColor: context.positive,
                          checkColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12.0,
                            vertical: 6.0,
                          ),
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                final newSet = Set<int>.from(_selectedIndices);
                                if (val) {
                                  newSet.add(index);
                                } else {
                                  newSet.remove(index);
                                }
                                _selectedIndices = newSet;
                              });
                            }
                          },
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  tx['description'] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                    // Deselected rows are de-emphasised by
                                    // colour (faint) rather than a noisy
                                    // strikethrough.
                                    color: isSelected
                                        ? context.textPrimary
                                        : context.textFaint,
                                  ),
                                ),
                              ),
                              if (isDuplicate) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: context.warning.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    l.impAlreadyImported,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: context.warning,
                                    ),
                                  ),
                                ),
                              ],
                              // OCR-sourced rows can have misread amounts/
                              // dates — badge them so the user verifies.
                              if (tx['from_ocr'] == true) ...[
                                const SizedBox(width: 8),
                                Tooltip(
                                  message: Localizations.localeOf(context)
                                              .languageCode ==
                                          'es'
                                      ? 'Leído por OCR (escaneado) — verifica el monto y la fecha'
                                      : 'Read by OCR (scanned) — verify the amount and date',
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: context.info.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'OCR',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: context.info,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 3.0),
                            child: Row(
                              children: [
                                Text(
                                  tx['date'] ?? '',
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.3,
                                    color: isSelected
                                        ? context.textSubtle
                                        : context.textFaint,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                                // Which file this row came from — so a
                                // mis-parsed file is easy to spot (and
                                // exclude via the chips above).
                                if (tx['source_file'] != null) ...[
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '· ${tx['source_file']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: context.textFaint,
                                      ),
                                    ),
                                  ),
                                ],
                                // Auto-assigned category (rule-based at
                                // import time). Shown as a faint chip so the
                                // user can sanity-check the bucketing before
                                // confirming.
                                if ((tx['category'] ?? '')
                                    .toString()
                                    .isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '· ${prettyCategory(primary: tx['category'].toString())}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: context.textFaint,
                                      ),
                                    ),
                                  ),
                                ],
                                const Spacer(),
                                Text(
                                  formatCurrencyAmount(
                                    double.tryParse('${tx['amount']}') ?? 0,
                                    (tx['currency'] ?? 'MXN').toString(),
                                  ),
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    // Income green / expense neutral when
                                    // selected; faint when deselected.
                                    color: !isSelected
                                        ? context.textFaint
                                        : ((double.tryParse(
                                                        '${tx['amount']}') ??
                                                    0) >=
                                                0
                                            ? context.positive
                                            : context.textPrimary),
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                                if (isAutoDeselected) ...[
                                  const SizedBox(width: 10),
                                  Tooltip(
                                    message: l.impAutoDeselectedTooltip,
                                    child: Icon(
                                      Icons.info_outline,
                                      size: 15,
                                      color: context.warning
                                          .withValues(alpha: 0.8),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.positive,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _confirmImport,
                      child: Text(
                        _selectedIndices.length == 1
                            ? l.impImportOneTransaction
                            : l.impImportNTransactions(_selectedIndices.length),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () =>
                        setState(() => _previewTransactions = null),
                    child: Center(
                      child: Text(
                        l.actionCancel,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 32),
            if (_selectedFiles.isNotEmpty && _previewTransactions == null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_requiresPassword)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24.0),
                      child: TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l.impPdfPassword,
                          filled: true,
                          fillColor: context.tint(0.05),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.positive,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: (_isUploading || _isReadingFiles) ? null : _uploadFile,
                      child: _isUploading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text(
                              l.impProcessStatement,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ),
            if (_message != null && _previewTransactions == null) ...[
              const SizedBox(height: 24),
              Builder(builder: (context) {
                // Theme-tuned semantic colors instead of raw *Accent shades,
                // which washed out against the tinted background (the
                // "hard to read" message). Error/warning/success each get a
                // matching icon + a high-contrast text color.
                final Color tone = _messageIsError
                    ? context.negative
                    : (_requiresPassword ? context.warning : context.positive);
                final IconData icon = _messageIsError
                    ? Icons.error_outline
                    : (_requiresPassword
                        ? Icons.lock_outline
                        : Icons.check_circle_outline);
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tone.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(icon, color: tone, size: 20),
                      ),
                      Flexible(
                        child: Text(
                          _message!,
                          style: TextStyle(
                            color: tone,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
