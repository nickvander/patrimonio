import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({Key? key}) : super(key: key);

  @override
  _ImportScreenState createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final ApiService _apiService = ApiService();
  bool _isUploading = false;
  PlatformFile? _selectedFile;
  List<dynamic>? _previewTransactions;
  List<dynamic>? _accounts;
  String? _selectedAccountId;
  String? _message;

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
    );

    if (result != null) {
      setState(() {
        _selectedFile = result.files.first;
        _previewTransactions = null;
        _message = null;
      });
    }
  }

  Future<void> _uploadFile() async {
    if (_selectedFile == null) return;

    setState(() {
      _isUploading = true;
      _message = null;
    });

    try {
      final response = await _apiService.uploadStatement(
        _selectedFile!.name,
        _selectedFile!.bytes!,
      );

      setState(() {
        _message = response['message'];
        _isUploading = false;
        _previewTransactions = response['transactions'];
      });
      
      if (response['status'] == 'success') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Found ${response['transactions_count']} transactions.')),
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
    if (_selectedAccountId == null || _previewTransactions == null) return;

    setState(() {
      _isUploading = true;
    });

    try {
      final response = await _apiService.confirmImport(
        _selectedAccountId!,
        _previewTransactions!,
      );

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
      appBar: AppBar(
        title: const Text('Import Statement'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Upload Account Statement',
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
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10, width: 2),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.upload_file, size: 64, color: Color(0xFF00E676)),
                      const SizedBox(height: 16),
                      if (_selectedFile != null)
                        Column(
                          children: [
                            Text(_selectedFile!.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('${(_selectedFile!.size / 1024).toStringAsFixed(1)} KB', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        )
                      else
                        const Text('No file selected'),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isUploading ? null : _pickFile,
                        child: const Text('Select File'),
                      ),
                    ],
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                    const Text('Assign to Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                   const SizedBox(height: 12),
                   if (_accounts != null)
                     DropdownButtonFormField<String>(
                       value: _selectedAccountId,
                       decoration: InputDecoration(
                         filled: true,
                         fillColor: Colors.white.withOpacity(0.05),
                         border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                       ),
                       items: _accounts!.map((acc) {
                         return DropdownMenuItem<String>(
                           value: acc['id'],
                           child: Text('${acc['institution_name']} - ${acc['name']}'),
                         );
                       }).toList(),
                       onChanged: (val) => setState(() => _selectedAccountId = val),
                     )
                   else
                     const CircularProgressIndicator(),
                   const SizedBox(height: 32),
                   const Text('Preview Transactions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                   const SizedBox(height: 16),
                   SizedBox(
                     width: double.infinity,
                     child: DataTable(
                       columns: const [
                         DataColumn(label: Text('Date')),
                         DataColumn(label: Text('Description')),
                         DataColumn(label: Text('Amount')),
                       ],
                       rows: _previewTransactions!.map((tx) {
                         return DataRow(cells: [
                           DataCell(Text(tx['date'] ?? '')),
                           DataCell(Text(tx['description'] ?? '')),
                           DataCell(Text('${tx['currency']} ${tx['amount']}')),
                         ]);
                       }).toList(),
                     ),
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
                       child: const Text('Confirm & Save', style: TextStyle(fontWeight: FontWeight.bold)),
                     ),
                   ),
                   const SizedBox(height: 12),
                   TextButton(
                     onPressed: () => setState(() => _previewTransactions = null),
                     child: const Center(child: Text('Cancel', style: TextStyle(color: Colors.grey))),
                   ),
                ],
              ),
            const SizedBox(height: 32),
            if (_selectedFile != null && _previewTransactions == null)
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
                      : const Text('Process Statement', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            if (_message != null && _previewTransactions == null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _message!.contains('failed') ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_message!, style: TextStyle(color: _message!.contains('failed') ? Colors.redAccent : Colors.greenAccent)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
