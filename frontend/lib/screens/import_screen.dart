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
import '../theme/typography.dart';
import '../l10n/app_localizations.dart';

/// Outcome of the post-parse account auto-match, surfaced as a cue under
/// the destination dropdown so the selection (or its absence) is never
/// silent. `created` is the inline "I just made the account it asked for"
/// state — distinct from `matched` so the copy can say so.
enum _AccountCue { none, matched, created, noMatch }

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
  // Auto-match outcome for the cue under the account dropdown (see
  // [_AccountCue]). Drives the green "matched/created" or amber "no match"
  // line so the dropdown never silently goes blank.
  _AccountCue _accountCue = _AccountCue.none;
  // Statement summary, computed once when the preview loads (in
  // [_initializeSelection]) and rendered as the stat strip at the top of the
  // review screen: total inflow / outflow and the covered date range.
  double _sumInflow = 0;
  double _sumOutflow = 0;
  DateTime? _minDate;
  DateTime? _maxDate;
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

    // Statement summary (inflow / outflow / covered date range) for the
    // review-screen stat strip. Computed once here over every parsed row —
    // a stable "here's what we found", independent of the live selection.
    double inflow = 0, outflow = 0;
    DateTime? minD, maxD;
    for (final tx in _previewTransactions!) {
      final amt = double.tryParse('${tx['amount']}') ?? 0.0;
      if (amt >= 0) {
        inflow += amt;
      } else {
        outflow += amt;
      }
      final d = DateTime.tryParse((tx['date'] ?? '').toString());
      if (d != null) {
        if (minD == null || d.isBefore(minD)) minD = d;
        if (maxD == null || d.isAfter(maxD)) maxD = d;
      }
    }
    _sumInflow = inflow;
    _sumOutflow = outflow;
    _minDate = minD;
    _maxDate = maxD;
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
          _autoSelectMatchingAccount();
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
            // The account they were prompted to create now exists and is the
            // destination — flip the amber "no match" cue to a green "created".
            _accountCue = _AccountCue.created;
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

  /// Upload header: "Processing X of Y" + a DETERMINATE bar + the running
  /// transaction count. A bar scales to any batch size (118 files read
  /// cleanly), unlike a 3-digit count crammed inside a spinner ring.
  Widget _buildUploadHeader(AppLocalizations l) {
    final total =
        _fileStatuses.isEmpty ? _selectedFiles.length : _fileStatuses.length;
    final done = _fileStatuses.where((s) => s.isDone).length;
    final txns = _fileStatuses
        .where((s) => s.status == 'ok')
        .fold<int>(0, (a, s) => a + s.count);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                total == 1
                    ? l.impProcessingOneFile
                    : l.impProcessingProgress(done, total),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: context.info,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: total > 0 ? done / total : null,
            minHeight: 6,
            backgroundColor: context.tint(0.08),
            valueColor: AlwaysStoppedAnimation<Color>(context.info),
          ),
        ),
        if (txns > 0) ...[
          const SizedBox(height: 6),
          Text(
            l.impFileTransactions(txns),
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
        ],
      ],
    );
  }

  /// Scanned / photographed statements are read with OCR — the slow step.
  Widget _buildOcrHint(AppLocalizations l) {
    return Padding(
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
    );
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// Tiny pill used on a preview row (duplicate / OCR flags).
  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style:
            TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  /// After a parse, auto-select the destination account that matches the
  /// statement: first by exact CLABE, then by institution/name. Falls back to
  /// the default (first account) when nothing matches — the user can still
  /// pick or create one (which pre-fills from the parsed account info).
  void _autoSelectMatchingAccount() {
    _accountCue = _AccountCue.none;
    final info = _accountInfo;
    final accounts = _accounts;
    if (info == null || accounts == null || accounts.isEmpty) return;
    final clabe = (info['clabe'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    final inst = (info['institution'] ?? '').toString().toLowerCase();

    if (clabe.isNotEmpty) {
      for (final a in accounts) {
        final ac = (a['clabe'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
        if (ac.isNotEmpty && ac == clabe) {
          _selectedAccountId = a['id']?.toString();
          _accountCue = _AccountCue.matched;
          return;
        }
      }
    }
    if (inst.isNotEmpty) {
      final key = inst.split(RegExp(r'[ —-]')).first; // "nu" / "cetesdirecto"
      for (final a in accounts) {
        final hay =
            '${a['institution_name'] ?? ''} ${a['name'] ?? ''}'.toLowerCase();
        if (key.length >= 2 && hay.contains(key)) {
          _selectedAccountId = a['id']?.toString();
          _accountCue = _AccountCue.matched;
          return;
        }
      }
    }

    // Recognised statement but no matching account (common on the first import
    // of a new bank). Clear the default (the first account, likely unrelated,
    // e.g. a US Plaid one) so the user is nudged to create the right account
    // (which pre-fills name/balance/CLABE) — and flag it for the cue below.
    _selectedAccountId = null;
    _accountCue = _AccountCue.noMatch;
  }

  /// Name of the currently-selected account, for the "matched" cue.
  String _selectedAccountName() {
    final a = (_accounts ?? const []).cast<dynamic>().firstWhere(
          (a) => a['id']?.toString() == _selectedAccountId,
          orElse: () => null,
        );
    if (a == null) return '';
    final inst = (a['institution_name'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    return inst.isNotEmpty ? '$inst · $name' : name;
  }

  static const _monthsEn = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const _monthsEs = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun', //
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
  ];

  /// Compact, localized date-range label ("Jan – Dec 2025", "ene – dic 2025",
  /// "Jan 2024 – Mar 2025"). Built from a small month table rather than
  /// `DateFormat(locale)` — the app never initializes intl locale data, so a
  /// localized DateFormat would throw.
  String _formatDateRange(DateTime a, DateTime b, bool es) {
    final m = es ? _monthsEs : _monthsEn;
    String my(DateTime d) => '${m[d.month - 1]} ${d.year}';
    if (a.year == b.year) {
      if (a.month == b.month) return my(a);
      return '${m[a.month - 1]} – ${my(b)}';
    }
    return '${my(a)} – ${my(b)}';
  }

  /// One compact stat tile for the import-summary strip — mirrors the
  /// dashboard's `_StatTile` (tiny caps label + ledger-figure value) so the
  /// review screen reads as native app surface, not a bespoke import widget.
  Widget _statTile(
    String label,
    String value,
    Color accent, {
    bool emphasized = false,
    Color? valueColor,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(emphasized ? 16 : 14, 11, 14, 11),
      decoration: BoxDecoration(
        color: emphasized
            ? accent.withValues(alpha: 0.06)
            : context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: emphasized ? accent.withValues(alpha: 0.32) : context.hairline,
          width: emphasized ? 1.2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!emphasized) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w700,
                    color: emphasized ? accent : context.textSubtle,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: brandDisplayStyle(
              fontSize: emphasized ? 19 : 16,
              fontWeight: FontWeight.w700,
              color: valueColor ?? context.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// Loud teal callout when the statement bundles extra accounts beyond the
  /// primary one — Nu cajitas (savings vaults) or a Banamex Pagaré/Ahorro
  /// section. Each needs its own destination below or it's skipped; the bare
  /// secondary panel was easy to miss, which read as "it only made one
  /// account". Hidden when there are no bundled sections.
  Widget _buildSecondaryHint() {
    if (_secondaryLabels.isEmpty) return const SizedBox.shrink();
    final es = Localizations.localeOf(context).languageCode == 'es';
    final names = _secondaryLabels.join(', ');
    final n = _secondaryLabels.length;
    final text = es
        ? 'Este estado de cuenta también incluye $n cajita(s)/cuenta(s): '
            '$names. Asígnalas (o crea una subcuenta) en la tarjeta de abajo, '
            'o esos movimientos no se importarán.'
        : 'This statement also bundles $n cajita(s)/account(s): $names. '
            'Assign each (or create a sub-account) in the card below, or those '
            "rows won't be imported.";
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.tealAccent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.tealAccent.withValues(alpha: 0.40)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.savings_outlined, size: 18, color: context.tealAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  fontSize: 12.5, height: 1.35, color: context.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  /// Stat strip at the top of the review screen: transactions found, total
  /// inflow / outflow, and the covered date range — the at-a-glance "here's
  /// what this statement holds" that the bare dropdown never gave.
  Widget _buildImportSummary(AppLocalizations l) {
    final txns = _previewTransactions;
    if (txns == null || txns.isEmpty) return const SizedBox.shrink();
    final es = Localizations.localeOf(context).languageCode == 'es';
    final cur = (txns.first['currency'] ?? 'MXN').toString();
    final fmt = moneyFormat(cur);
    final nFiles = _fileGroups.isEmpty ? _selectedFiles.length : _fileGroups.length;
    final range = (_minDate != null && _maxDate != null)
        ? _formatDateRange(_minDate!, _maxDate!, es)
        : null;

    final tiles = <Widget>[
      _statTile(
        l.impSummaryFound,
        '${txns.length}',
        context.info,
        emphasized: true,
        valueColor: context.info,
      ),
      _statTile(
        l.impSummaryInflow,
        fmt.format(_sumInflow),
        context.positive,
        valueColor: context.positive,
      ),
      _statTile(
        l.impSummaryOutflow,
        fmt.format(_sumOutflow),
        context.negative,
        valueColor: context.negative,
      ),
    ];

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(builder: (ctx, c) {
              final n = tiles.length;
              double width(double max) => max >= 620
                  ? (max - (n - 1) * 10) / n
                  : max >= 420
                      ? (max - 10) / 2 - 0.5
                      : max;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: tiles
                    .map((t) =>
                        SizedBox(width: width(c.maxWidth), child: t))
                    .toList(),
              );
            }),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.description_outlined,
                    size: 14, color: context.textFaint),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    [
                      l.impSummaryFiles(nFiles),
                      ?range,
                    ].join('  ·  '),
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Green "matched / created" or amber "no match" line under the
  /// destination dropdown, driven by [_accountCue].
  Widget _buildAccountCue(AppLocalizations l) {
    switch (_accountCue) {
      case _AccountCue.matched:
      case _AccountCue.created:
        final text = _accountCue == _AccountCue.created
            ? l.impAccountCreatedCue(_selectedAccountName())
            : l.impAccountMatched(_selectedAccountName());
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(Icons.check_circle, size: 14, color: context.positive),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(fontSize: 12, color: context.positive),
                ),
              ),
            ],
          ),
        );
      case _AccountCue.noMatch:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 14, color: context.warning),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  l.impNoAccountMatch,
                  style: TextStyle(fontSize: 12, color: context.warning),
                ),
              ),
            ],
          ),
        );
      case _AccountCue.none:
        return const SizedBox.shrink();
    }
  }

  Widget _buildSelectedHeader(AppLocalizations l) {
    final totalBytes = _selectedFiles.fold<int>(0, (a, f) => a + f.size);
    final count = _selectedFiles.length == 1
        ? l.impOneFileSelected
        : l.impNFilesSelected(_selectedFiles.length);
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '$count · ${_fmtSize(totalBytes)}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: context.textPrimary,
        ),
      ),
    );
  }

  /// ONE unified file list. Idle rows show size + a remove button; during
  /// upload the same rows show live status (waiting → parsing → ✓ count /
  /// skipped) — no more two separate lists. Virtualised so 100+ files stay
  /// smooth.
  Widget _buildFileList(AppLocalizations l, {required bool uploading}) {
    final statusByName = {for (final s in _fileStatuses) s.name: s};
    const rowExtent = 39.0;
    final height =
        (_selectedFiles.length * rowExtent + 6).clamp(rowExtent, 280).toDouble();
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: context.tint(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemCount: _selectedFiles.length,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            indent: 38,
            color: context.hairline.withValues(alpha: 0.5),
          ),
          itemBuilder: (_, i) => _fileListRow(
            l,
            _selectedFiles[i],
            statusByName[_selectedFiles[i].name],
            uploading,
            i,
          ),
        ),
      ),
    );
  }

  Widget _fileListRow(
    AppLocalizations l,
    PlatformFile file,
    ImportFileStatus? st,
    bool uploading,
    int index,
  ) {
    final Widget leading;
    final Widget trailing;
    if (uploading) {
      switch (st?.status) {
        case 'ok':
          leading = Icon(Icons.check_circle, size: 16, color: context.positive);
          trailing = Text(l.impFileTransactions(st!.count),
              style: TextStyle(fontSize: 12, color: context.textSubtle));
          break;
        case 'failed':
          leading =
              Icon(Icons.error_outline, size: 16, color: context.warning);
          trailing = Text(l.impFileSkipped,
              style: TextStyle(fontSize: 12, color: context.warning));
          break;
        case 'parsing':
          leading = const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2));
          trailing = Text(l.impFileParsing,
              style: TextStyle(fontSize: 12, color: context.textSubtle));
          break;
        default:
          leading = Icon(Icons.schedule_outlined,
              size: 16, color: context.textFaint);
          trailing = Text(l.impFileWaiting,
              style: TextStyle(fontSize: 12, color: context.textFaint));
      }
    } else {
      leading = Icon(Icons.insert_drive_file_outlined,
          size: 16, color: context.textSubtle);
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _fmtSize(file.size),
            style: TextStyle(
              fontSize: 11,
              color: context.textFaint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 15),
            tooltip: l.impRemoveFile,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(left: 6),
            constraints: const BoxConstraints(),
            color: context.textFaint,
            onPressed: (_isUploading || _isReadingFiles)
                ? null
                : () => _removeFileAt(index),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          SizedBox(width: 18, child: Center(child: leading)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: context.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          trailing,
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

  /// Pinned bottom action bar shown during review: Cancel + the primary
  /// "Import N transactions" button, always visible regardless of how far
  /// the preview list has scrolled.
  Widget _buildImportActionBar(AppLocalizations l) {
    final n = _selectedIndices.length;
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: Row(
            children: [
              TextButton(
                onPressed: _isUploading
                    ? null
                    : () => setState(() => _previewTransactions = null),
                child: Text(
                  l.actionCancel,
                  style: TextStyle(color: context.textSubtle),
                ),
              ),
              const Spacer(),
              Flexible(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.positive,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        context.positive.withValues(alpha: 0.4),
                    disabledForegroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                  ),
                  onPressed: (_isUploading || n == 0) ? null : _confirmImport,
                  icon: _isUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.download_done, size: 18),
                  label: Text(
                    n == 1
                        ? l.impImportOneTransaction
                        : l.impImportNTransactions(n),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
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
      // Pinned action bar during review so "Import N" is always visible
      // instead of buried under the (tall) preview list.
      bottomNavigationBar:
          _previewTransactions == null ? null : _buildImportActionBar(l),
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
                      // Idle → upload icon + helper text + the unified file
                      // list. Reading → small spinner + text. Uploading →
                      // header + DETERMINATE bar + the same unified list with
                      // live per-file status. The file count lives in text,
                      // never crammed inside a ring, so 100+ files read cleanly.
                      if (!_isUploading && !_isReadingFiles) ...[
                        Icon(Icons.upload_file,
                            size: 56, color: context.positive),
                        const SizedBox(height: 14),
                        if (_isDragging)
                          Text(
                            l.impDropToImport,
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: context.positive),
                          )
                        else if (kIsWeb && _selectedFiles.isEmpty)
                          Text(
                            l.impDropHint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13, color: context.textSubtle),
                          )
                        else if (!kIsWeb && _selectedFiles.isEmpty)
                          Text(l.impNoFilesSelected),
                        if (_selectedFiles.isNotEmpty) ...[
                          _buildSelectedHeader(l),
                          const SizedBox(height: 8),
                          _buildFileList(l, uploading: false),
                        ],
                      ],
                      if (_isReadingFiles) ...[
                        const SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _readingFileCount == null
                              ? l.impReadingFiles
                              : _readingFileCount == 1
                                  ? l.impReadingOneFile
                                  : l.impReadingNFiles(_readingFileCount!),
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: context.info),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l.impReadingHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12, color: context.textSubtle),
                        ),
                      ],
                      if (_isUploading) ...[
                        _buildUploadHeader(l),
                        const SizedBox(height: 14),
                        _buildOcrHint(l),
                        const SizedBox(height: 14),
                        _buildFileList(l, uploading: true),
                      ],
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
                  // At-a-glance statement summary (count + inflow/outflow +
                  // covered period) so the review screen leads with context.
                  _buildImportSummary(l),
                  const SizedBox(height: 20),
                  // Loud pointer when the statement bundles extra accounts
                  // (Nu cajitas / Banamex Pagaré) — these need their own
                  // destination or they're silently skipped, and the old
                  // secondary panel was easy to miss.
                  _buildSecondaryHint(),
                  // Destination-account assignment, grouped in one panel:
                  // dropdown + match cue + inline-create + any bundled
                  // secondary sections.
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: context.hairline),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.impAssignToAccount,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          if (_accounts != null)
                            DropdownButtonFormField<String>(
                              initialValue: _selectedAccountId,
                              isExpanded: true,
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: context.tint(0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              items: _accounts!.map((acc) {
                                final cur = (acc['currency'] as String? ?? '')
                                    .toUpperCase();
                                final label = cur.isNotEmpty
                                    ? '${acc['institution_name']} - ${acc['name']} ($cur)'
                                    : '${acc['institution_name']} - ${acc['name']}';
                                return DropdownMenuItem<String>(
                                  value: acc['id'],
                                  child: Text(label),
                                );
                              }).toList(),
                              onChanged: (val) {
                                setState(() {
                                  _selectedAccountId = val;
                                  // A manual pick supersedes the auto-match
                                  // cue — clear it rather than show stale copy.
                                  _accountCue = _AccountCue.none;
                                });
                                _recheckDuplicates();
                              },
                            )
                          else
                            const CircularProgressIndicator(),
                          // Cue so an auto-match (or the lack of one) is
                          // obvious, instead of the dropdown silently blanking.
                          _buildAccountCue(l),
                          const SizedBox(height: 8),
                          // Statements from a bank you haven't linked (e.g.
                          // Banamex) have no destination yet — let the user
                          // make one inline, pre-set to the statements' currency.
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _openCreateAccount,
                              icon: const Icon(Icons.add, size: 18),
                              label: Text(l.impCreateAccountForImport),
                            ),
                          ),
                          // Per-section destination pickers when a statement
                          // bundles more than one account (Banamex primary +
                          // Pagaré/Ahorro).
                          if (_secondaryLabels.isNotEmpty)
                            ..._buildSecondaryPickers(context),
                        ],
                      ),
                    ),
                  ),
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

                      final amount =
                          double.tryParse('${tx['amount']}') ?? 0.0;
                      final isIncome = amount >= 0;
                      void toggle() => setState(() {
                            final s = Set<int>.from(_selectedIndices);
                            isSelected ? s.remove(index) : s.add(index);
                            _selectedIndices = s;
                          });
                      final meta = [
                        (tx['date'] ?? '').toString(),
                        if (tx['source_file'] != null)
                          tx['source_file'].toString(),
                        if ((tx['category'] ?? '').toString().isNotEmpty)
                          prettyCategory(primary: tx['category'].toString()),
                      ].where((s) => s.isNotEmpty).join('  ·  ');
                      // Dense, divider-separated row matching the main
                      // transactions list (no bulky per-row Card). Tap the row
                      // or the checkbox to toggle.
                      return InkWell(
                        onTap: toggle,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? context.tint(0.04)
                                : Colors.transparent,
                            border: Border(
                              bottom: BorderSide(
                                color: context.hairline.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 7),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 26,
                                height: 26,
                                child: Checkbox(
                                  value: isSelected,
                                  activeColor: context.positive,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  onChanged: (_) => toggle(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            tx['description'] ?? '',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                              height: 1.2,
                                              color: isSelected
                                                  ? context.textPrimary
                                                  : context.textFaint,
                                            ),
                                          ),
                                        ),
                                        if (isDuplicate) ...[
                                          const SizedBox(width: 6),
                                          _miniBadge(
                                              l.impAlreadyImported,
                                              context.warning),
                                        ],
                                        if (tx['from_ocr'] == true) ...[
                                          const SizedBox(width: 6),
                                          _miniBadge('OCR', context.info),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      meta,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
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
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                formatCurrencyAmount(
                                  amount,
                                  (tx['currency'] ?? 'MXN').toString(),
                                ),
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: !isSelected
                                      ? context.textFaint
                                      : (isIncome
                                          ? context.positive
                                          : context.textPrimary),
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                              if (isAutoDeselected) ...[
                                const SizedBox(width: 8),
                                Tooltip(
                                  message: l.impAutoDeselectedTooltip,
                                  child: Icon(Icons.info_outline,
                                      size: 15,
                                      color: context.warning
                                          .withValues(alpha: 0.8)),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                    ),
                  ),
                  // Primary "Import" + Cancel now live in the pinned bottom
                  // action bar (see _buildImportActionBar) so they're always
                  // reachable without scrolling past the long preview list.
                  const SizedBox(height: 8),
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
