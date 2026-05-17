import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';

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
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(48),
                  decoration: BoxDecoration(
                    color: context.tint(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: context.hairline, width: 2),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.upload_file,
                        size: 64,
                        color: Color(0xFF00E676),
                      ),
                      const SizedBox(height: 16),
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
                                              onPressed: _isUploading
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
                        )
                      else
                        const Text('No files selected'),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isUploading ? null : _pickFile,
                        child: Text(
                          _selectedFiles.isEmpty
                              ? 'Select file(s)'
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
                            child: const Text(
                              'Select all',
                              style: TextStyle(color: Color(0xFF00E676)),
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
                                ? const Color(0xFF00E676).withValues(alpha: 0.5)
                                : context.hairline,
                            width: 1,
                          ),
                        ),
                        margin: const EdgeInsets.only(bottom: 8.0),
                        child: CheckboxListTile(
                          value: isSelected,
                          activeColor: const Color(0xFF00E676),
                          checkColor: Colors.black,
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
                        backgroundColor: const Color(0xFF00E676),
                        foregroundColor: Colors.black,
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
                        backgroundColor: const Color(0xFF00E676),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _isUploading ? null : _uploadFile,
                      child: _isUploading
                          ? const CircularProgressIndicator(color: Colors.black)
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
