import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/import_screen.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/import_reconciliation_panel.dart';

// Where the reconciliation call fires, and the safety property that hangs
// off it.
//
// The check rides the PREVIEW stage — the same moment `/check-duplicates`
// runs, right after a parse and again whenever the destination account
// changes — so the user never has to ask for it. And whatever it says, the
// confirm button STAYS ENABLED: real statements carry fees and adjustments
// the parsers miss, so a hard gate would block legitimate imports.
//
// Driven through the house seams: an `extends ApiService` fake plus a fake
// FilePicker, so no HTTP and no OS dialog run on the test VM.

class _FakeImportApi extends ApiService {
  _FakeImportApi(this.reconciliation);

  final List<Map<String, dynamic>> reconciliation;

  /// Every `reconcileImport` payload this fake saw, in order.
  final List<Map<String, List<dynamic>>> reconcileCalls = [];
  int duplicateCalls = 0;

  static final List<Map<String, dynamic>> previewRows = [
    {
      'date': '2026-01-05',
      'description': 'OXXO GAS SANTA FE',
      'amount': -60.0,
      'currency': 'MXN',
      'balance_after': 940.0,
      'source_file': 'ENERO2026.pdf',
    },
    {
      'date': '2026-01-19',
      'description': 'DEPOSITO NOMINA',
      'amount': 1200.0,
      'currency': 'MXN',
      'balance_after': 2140.0,
      'source_file': 'ENERO2026.pdf',
    },
  ];

  @override
  Future<Map<String, dynamic>> getDashboardOverview({
    bool forceRefresh = false,
  }) async => {
    'accounts': [
      {
        'id': 'acct-1',
        'name': 'Perfiles',
        'institution_name': 'Banamex',
        'currency': 'MXN',
      },
    ],
  };

  @override
  Future<List<dynamic>> getImportCoverage() async => const [];

  @override
  Future<Map<String, dynamic>> uploadStatements(
    List<PlatformFile> files, {
    String? password,
    ImportProgressCallback? onProgress,
    int? maxBatchBytes,
  }) async => {
    'status': 'success',
    'message': 'Parsed 2 transactions',
    'transactions_count': previewRows.length,
    'transactions': previewRows,
  };

  @override
  Future<Set<int>> checkImportDuplicates(
    String accountId,
    List<dynamic> transactions,
  ) async {
    duplicateCalls++;
    return <int>{};
  }

  @override
  Future<List<AccountReconciliation>> reconcileImport(
    Map<String, List<dynamic>> transactionsByAccount,
  ) async {
    reconcileCalls.add(transactionsByAccount);
    return reconciliation.map(AccountReconciliation.fromJson).toList();
  }
}

class _FakePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'ENERO2026.pdf',
      size: 4,
      bytes: Uint8List.fromList([1, 2, 3, 4]),
    ),
  ]);
}

Map<String, dynamic> _reconciliation(
  String status, {
  String? unavailableReason,
  double? statementClosing,
  double? computedClosing,
  double? difference,
  List<Map<String, dynamic>> candidates = const [],
}) => {
  'account_id': 'acct-1',
  'account_name': 'Banamex Perfiles',
  'currency': 'MXN',
  'status': status,
  'statements': [
    {
      'file': 'ENERO2026.pdf',
      'period_start': '2026-01-05',
      'period_end': '2026-01-19',
      'currency': 'MXN',
      'status': status,
      'unavailable_reason': unavailableReason,
      'statement_opening_balance': statementClosing == null ? null : 1000.0,
      'statement_closing_balance': statementClosing,
      'computed_closing_balance': computedClosing,
      'difference': difference,
      'incoming_rows': 2,
      'duplicate_rows': 0,
      'existing_rows_in_period': 1,
      'candidates': candidates,
    },
  ],
};

/// Pump the import screen, pick a file and parse it — i.e. reach the review
/// stage the way a user does.
Future<void> _reachPreview(WidgetTester tester, _FakeImportApi api) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ImportScreen(api: api),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('Select files'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Process statement'));
  await tester.pumpAndSettle();
}

/// The pinned confirm button, found by its label rather than by type (the
/// screen has other ElevatedButtons).
ElevatedButton _confirmButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.textContaining('Import 2 Transactions'),
        matching: find.byType(ElevatedButton),
      ),
    );

void main() {
  // `FilePicker.platform` has no registered implementation on the test VM
  // (reading it before assignment throws), so we only install the fake.
  setUpAll(() => FilePicker.platform = _FakePicker());

  testWidgets('the reconcile call rides the preview stage, with the rows '
      'grouped by destination account', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeImportApi([
      _reconciliation(
        'reconciled',
        statementClosing: 2140.0,
        computedClosing: 2140.0,
        difference: 0.0,
      ),
    ]);
    await _reachPreview(tester, api);

    // Fired without any extra user step, alongside the duplicate check.
    expect(api.duplicateCalls, greaterThanOrEqualTo(1));
    expect(api.reconcileCalls, isNotEmpty);
    expect(api.reconcileCalls.first.keys.toList(), ['acct-1']);
    expect(api.reconcileCalls.first['acct-1']!.length, 2);
    // The raw preview rows go over the wire, `source_file` and all — that's
    // the grouping key the backend reconciles per statement.
    expect(
      (api.reconcileCalls.first['acct-1']!.first as Map)['source_file'],
      'ENERO2026.pdf',
    );

    expect(find.byType(ImportReconciliationPanel), findsOneWidget);
    expect(find.text('Balances to the centavo'), findsOneWidget);
  });

  // One test per status: the panel renders, and the confirm button is still
  // pressable. This is the safety property — guidance, never a gate.
  final cases = <String, Map<String, dynamic>>{
    'reconciled': _reconciliation(
      'reconciled',
      statementClosing: 2140.0,
      computedClosing: 2140.0,
      difference: 0.0,
    ),
    'reconciled_after_duplicate_skip': _reconciliation(
      'reconciled_after_duplicate_skip',
      statementClosing: 2140.0,
      computedClosing: 2140.0,
      difference: 0.0,
    ),
    'explained_by_existing_transactions': _reconciliation(
      'explained_by_existing_transactions',
      statementClosing: 2140.0,
      computedClosing: 2040.0,
      difference: 100.0,
      candidates: [
        {
          'transaction_id': 'tx-1',
          'date': '2026-01-14',
          'description': 'PAGO DUPLICADO',
          'amount': -100.0,
          'kind': 'double_entry_in_period',
        },
      ],
    ),
    'unexplained': _reconciliation(
      'unexplained',
      statementClosing: 2140.0,
      computedClosing: 2113.5,
      difference: 26.5,
    ),
    'unavailable': _reconciliation(
      'unavailable',
      unavailableReason: 'no_running_balance',
    ),
  };

  for (final entry in cases.entries) {
    testWidgets('confirm stays enabled when a statement is ${entry.key}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = _FakeImportApi([entry.value]);
      await _reachPreview(tester, api);

      expect(
        find.byType(ImportReconciliationPanel),
        findsOneWidget,
        reason: '${entry.key}: the panel should render',
      );
      expect(
        _confirmButton(tester).onPressed,
        isNotNull,
        reason: '${entry.key}: the import must never be blocked',
      );
    });
  }

  testWidgets('a reconciliation that could not be fetched simply hides the '
      'panel — it never blocks confirm either', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeImportApi(const []);
    await _reachPreview(tester, api);

    expect(find.byType(ImportReconciliationPanel), findsNothing);
    expect(_confirmButton(tester).onPressed, isNotNull);
  });
}
