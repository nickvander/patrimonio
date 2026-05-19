import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../services/file_drop_web.dart';

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
  List<dynamic>? _accounts;
  String? _selectedAccountId;
  String? _message;

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
        const SnackBar(
          content: Text('Wait for the current import to finish before adding more files.'),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          files.length == 1
              ? 'Added 1 file from drop'
              : 'Added ${files.length} files from drop',
        ),
      ),
    );
  }

  Future<void> _fetchAccounts() async {
    try {
      final overview = await _apiService.getDashboardOverview();
      setState(() {
        _accounts = overview['accounts'];
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
    for (int i = 0; i < _previewTransactions!.length; i++) {
      final desc = (_previewTransactions![i]['description'] ?? '')
          .toString()
          .toUpperCase();
      final shouldDeselect = _autoDeselectPatterns.any((p) => desc.contains(p));
      if (!shouldDeselect) {
        _selectedIndices.add(i);
      }
    }
  }

  Future<void> _uploadFile() async {
    if (_selectedFiles.isEmpty) return;

    setState(() {
      _isUploading = true;
      _message = null;
    });

    try {
      final response = await _apiService.uploadStatements(
        _selectedFiles,
        password: _passwordController.text.trim().isEmpty
            ? null
            : _passwordController.text.trim(),
      );

      setState(() {
        _message = response['message'];
        _isUploading = false;

        if (response['status'] == 'password_required') {
          _requiresPassword = true;
          _previewTransactions = null;
        } else if (response['status'] == 'success') {
          _previewTransactions = response['transactions'];
          _initializeSelection();
        }
      });

      if (response['status'] == 'success' && _previewTransactions != null) {
        final autoDeselected =
            _previewTransactions!.length - _selectedIndices.length;
        final msg = 'Found ${response['transactions_count']} transactions.';
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              autoDeselected > 0
                  ? '$msg ($autoDeselected auto-deselected as informational)'
                  : msg,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _message = 'Upload failed: $e';
        _isUploading = false;
      });
    }
  }

  Future<void> _confirmImport() async {
    if (_selectedAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please select a destination account first.',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      );
      return;
    }
    if (_previewTransactions == null) return;

    // Only send selected transactions
    final selectedTxs = <dynamic>[];
    for (int i = 0; i < _previewTransactions!.length; i++) {
      if (_selectedIndices.contains(i)) {
        selectedTxs.add(_previewTransactions![i]);
      }
    }

    if (selectedTxs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No transactions selected. Please check at least one.'),
        ),
      );
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      final response = await _apiService.confirmImport(
        _selectedAccountId!,
        selectedTxs,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response['message'] ?? 'Import successful')),
      );
      Navigator.pop(context);
    } catch (e) {
      setState(() {
        _message = 'Confirmation failed: $e';
        _isUploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import statement')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Upload account statement',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Upload CSV or PDF statements from Nu Mexico, Banamex, or Cetesdirecto. We will automatically detect the format.',
              style: TextStyle(color: Colors.grey),
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
                                  ? 'Reading files…'
                                  : _readingFileCount == 1
                                      ? 'Reading 1 file…'
                                      : 'Reading $_readingFileCount files…',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: context.info,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Loading file contents into the browser '
                              'before sending. This step is local — '
                              'no upload yet.',
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
                        Column(
                          children: [
                            Text(
                              _selectedFiles.length == 1
                                  ? 'Processing 1 file…'
                                  : 'Processing ${_selectedFiles.length} files…',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: context.info,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Large batches can take 30-120 seconds — '
                              'each PDF is parsed individually on the server.',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.textSubtle,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      // Drag / idle helper text — hidden while
                      // uploading OR reading so the status block
                      // above owns the user's attention.
                      if (!_isUploading && !_isReadingFiles && _isDragging)
                        Text(
                          'Drop to import',
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
                          'Drop CSV or PDF files anywhere on this page, or select them manually below.',
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
                        const Text('No files selected'),
                      if (_selectedFiles.isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_selectedFiles.length} file${_selectedFiles.length == 1 ? '' : 's'} selected',
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
                                              tooltip: 'Remove',
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
                              ? 'Select files'
                              : 'Add more files',
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
                  const Text(
                    'Assign to account',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                        return DropdownMenuItem<String>(
                          value: acc['id'],
                          child: Text(
                            '${acc['institution_name']} - ${acc['name']}',
                          ),
                        );
                      }).toList(),
                      onChanged: (val) =>
                          setState(() => _selectedAccountId = val),
                    )
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 32),

                  // Header row with title and selection controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          'Preview (${_selectedIndices.length}/${_previewTransactions!.length} selected)',
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
                              'Select all',
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
                            child: const Text(
                              'Deselect all',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
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
                            horizontal: 16.0,
                            vertical: 4.0,
                          ),
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
                          title: Text(
                            tx['description'] ?? '',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: isSelected ? null : Colors.grey,
                              decoration: isSelected
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Row(
                              children: [
                                Text(
                                  tx['date'] ?? '',
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.grey[400]
                                        : Colors.grey[600],
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${tx['currency']} ${tx['amount']}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.grey,
                                  ),
                                ),
                                if (isAutoDeselected) ...[
                                  const SizedBox(width: 12),
                                  Tooltip(
                                    message:
                                        'Auto-deselected: informational entry',
                                    child: Icon(
                                      Icons.info_outline,
                                      size: 16,
                                      color: Colors.amber.withValues(
                                        alpha: 0.7,
                                      ),
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
                        'Import ${_selectedIndices.length} Transaction${_selectedIndices.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () =>
                        setState(() => _previewTransactions = null),
                    child: const Center(
                      child: Text(
                        'Cancel',
                        style: TextStyle(color: Colors.grey),
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
                          labelText: 'PDF password (e.g. RFC)',
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
                          : const Text(
                              'Process statement',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ),
            if (_message != null && _previewTransactions == null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _message!.contains('failed')
                      ? Colors.red.withValues(alpha: 0.1)
                      : (_requiresPassword
                            ? Colors.amber.withValues(alpha: 0.1)
                            : Colors.green.withValues(alpha: 0.1)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    if (_requiresPassword)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.amberAccent,
                        ),
                      ),
                    Flexible(
                      child: Text(
                        _message!,
                        style: TextStyle(
                          color: _message!.contains('failed')
                              ? Colors.redAccent
                              : (_requiresPassword
                                    ? Colors.amberAccent
                                    : Colors.greenAccent),
                        ),
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
}
