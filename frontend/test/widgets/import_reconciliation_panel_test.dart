import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/utils/theme_colors.dart';
import 'package:patrimonio/widgets/import_reconciliation_panel.dart';

// The import-preview "Statement check" panel. Every case is built from a
// CANNED WIRE PAYLOAD through AccountReconciliation.fromJson, so the test
// covers the real `POST /imports/reconcile` vocabulary (snake_case statuses,
// explicit nulls, candidate kinds) and not just the Dart constructors.
//
// The load-bearing property: `unavailable` must NEVER read as success —
// different words, different icon family, different colour.

Map<String, dynamic> _statement({
  required String status,
  String file = 'ENERO2026.pdf',
  String? unavailableReason,
  double? statementClosing,
  double? computedClosing,
  double? difference,
  int incomingRows = 42,
  int duplicateRows = 0,
  List<Map<String, dynamic>> candidates = const [],
}) => {
  'file': file,
  'period_start': '2026-01-01',
  'period_end': '2026-01-31',
  'currency': 'MXN',
  'status': status,
  'unavailable_reason': unavailableReason,
  'statement_opening_balance': statementClosing == null ? null : 1000.0,
  'statement_closing_balance': statementClosing,
  'computed_closing_balance': computedClosing,
  'difference': difference,
  'incoming_rows': incomingRows,
  'duplicate_rows': duplicateRows,
  'existing_rows_in_period': 3,
  'candidates': candidates,
};

Map<String, dynamic> _account(
  List<Map<String, dynamic>> statements, {
  String status = 'reconciled',
  String name = 'Banamex Perfiles',
}) => {
  'account_id': 'acct-1',
  'account_name': name,
  'currency': 'MXN',
  'status': status,
  'statements': statements,
};

/// Money the way the panel must render it — through the house helper, so
/// this test asserts the VALUE and the currency without pinning the glyph
/// (which `utils/currency.dart` owns and has changed before).
String _mxn(double amount) => formatCurrencyAmount(amount, 'MXN');

BuildContext? _capturedContext;

Widget _host(
  List<Map<String, dynamic>> accounts, {
  Locale locale = const Locale('en'),
  double width = 900,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (context) {
        _capturedContext = context;
        return SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: ImportReconciliationPanel(
              accounts: accounts
                  .map(AccountReconciliation.fromJson)
                  .toList(growable: false),
            ),
          ),
        );
      },
    ),
  ),
);

void main() {
  setUp(() => _capturedContext = null);

  group('status affordances (en)', () {
    testWidgets('reconciled reads as a clean match', (tester) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(
              status: 'reconciled',
              statementClosing: 1150.0,
              computedClosing: 1150.0,
              difference: 0.0,
            ),
          ]),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Balances to the centavo'), findsOneWidget);
      expect(
        find.textContaining("The bank's closing balance matches"),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      // A zero difference is not printed as a row — it would be noise.
      expect(find.text('Difference'), findsNothing);
      expect(find.text('Statement closing balance'), findsOneWidget);
    });

    testWidgets('reconciled_after_duplicate_skip says how many rows are '
        'already here', (tester) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(
              status: 'reconciled_after_duplicate_skip',
              statementClosing: 1150.0,
              computedClosing: 1150.0,
              difference: 0.0,
              duplicateRows: 12,
            ),
          ], status: 'reconciled_after_duplicate_skip'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Balances once already-imported rows are skipped'),
        findsOneWidget,
      );
      expect(
        find.textContaining('12 rows on this statement are already'),
        findsOneWidget,
      );
      // Distinct from the plain green case, so "12 rows landed" is never
      // implied.
      expect(find.text('Balances to the centavo'), findsNothing);
    });

    testWidgets('explained shows the gap and names the transactions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(
              status: 'explained_by_existing_transactions',
              statementClosing: 1150.0,
              computedClosing: 1050.0,
              difference: 100.0,
              candidates: [
                {
                  'transaction_id': 'tx-1',
                  'date': '2026-01-14',
                  'description': 'OXXO GAS SANTA FE',
                  'amount': -60.0,
                  'kind': 'double_entry_in_period',
                },
                {
                  'transaction_id': 'tx-2',
                  'date': '2026-02-03',
                  'description': 'COMISION MANEJO DE CUENTA',
                  'amount': -40.0,
                  'kind': 'misdated_near_period',
                },
              ],
            ),
          ], status: 'explained_by_existing_transactions'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Explained by transactions you already have'),
        findsOneWidget,
      );
      // The sentence carries the exact gap and the count, and says plainly
      // what to do about it.
      expect(
        find.textContaining('off by exactly ${_mxn(100)}'),
        findsOneWidget,
      );
      expect(
        find.textContaining('the total of 2 transactions'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Likely duplicates to delete'),
        findsOneWidget,
      );

      // The candidate rows themselves: description, date, amount, and which
      // kind of mistake each one is.
      expect(
        find.text('Transactions that add up to the difference'),
        findsOneWidget,
      );
      expect(find.text('OXXO GAS SANTA FE'), findsOneWidget);
      expect(find.text('COMISION MANEJO DE CUENTA'), findsOneWidget);
      expect(find.text(_mxn(-60)), findsOneWidget);
      expect(find.text(_mxn(-40)), findsOneWidget);
      expect(
        find.textContaining('Already here, not on the statement'),
        findsOneWidget,
      );
      expect(
        find.textContaining("Dated outside this statement's period"),
        findsOneWidget,
      );
      expect(find.textContaining('Jan 14, 2026'), findsOneWidget);
      expect(find.text('Difference'), findsOneWidget);
    });

    testWidgets('unexplained states the difference and invents no cause', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(
              status: 'unexplained',
              statementClosing: 1150.0,
              computedClosing: 1123.5,
              difference: 26.5,
            ),
          ], status: 'unexplained'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text("Difference we can't explain"), findsOneWidget);
      expect(
        find.textContaining('Nothing in this account adds up to the gap'),
        findsOneWidget,
      );
      // The honest numbers, side by side.
      expect(find.text('Statement closing balance'), findsOneWidget);
      expect(find.text(_mxn(1150)), findsOneWidget);
      expect(find.text('After this import'), findsOneWidget);
      expect(find.text(_mxn(1123.5)), findsOneWidget);
      expect(find.text(_mxn(26.5)), findsOneWidget);
      // No fabricated explanation section.
      expect(
        find.text('Transactions that add up to the difference'),
        findsNothing,
      );
    });
  });

  group('unavailable is NOT success', () {
    testWidgets('no_running_balance says we could not check, with the reason', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(
              status: 'unavailable',
              unavailableReason: 'no_running_balance',
            ),
          ], status: 'unavailable'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not checked'), findsOneWidget);
      expect(
        find.textContaining("this bank's format carries no running balance"),
        findsOneWidget,
      );

      // Not the success copy, not the success icon family.
      expect(find.text('Balances to the centavo'), findsNothing);
      expect(
        find.text('Balances once already-imported rows are skipped'),
        findsNothing,
      );
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.byIcon(Icons.help_outline), findsOneWidget);

      // Not the success colour either.
      final icon = tester.widget<Icon>(find.byIcon(Icons.help_outline));
      final ctx = _capturedContext!;
      expect(icon.color, isNot(ctx.positive));
      expect(icon.color, ctx.textSubtle);

      // And no invented balances: the backend sent explicit nulls.
      expect(find.text('Statement closing balance'), findsNothing);
      expect(find.text('Difference'), findsNothing);
      expect(find.textContaining(_mxn(0)), findsNothing);
    });

    testWidgets('each unavailable_reason gets its own wording', (tester) async {
      for (final (reason, fragment) in const [
        ('balance_marker_only', 'only a period-total balance'),
        ('mixed_currency', 'it mixes currencies'),
      ]) {
        await tester.pumpWidget(
          _host([
            _account([
              _statement(status: 'unavailable', unavailableReason: reason),
            ], status: 'unavailable'),
          ]),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining(fragment),
          findsOneWidget,
          reason: 'reason $reason should render its own sentence',
        );
      }
    });

    testWidgets('an unknown status degrades to "not checked", never to green', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(status: 'some_future_status_we_dont_know'),
          ], status: 'some_future_status_we_dont_know'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not checked'), findsOneWidget);
      expect(find.text("We can't check this statement."), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });
  });

  group('layout', () {
    testWidgets('renders at phone width without overflow', (tester) async {
      await tester.pumpWidget(
        _host(width: 360, [
          _account([
            _statement(
              status: 'explained_by_existing_transactions',
              statementClosing: 1150.0,
              computedClosing: 1050.0,
              difference: 100.0,
              candidates: [
                {
                  'transaction_id': 'tx-1',
                  'date': '2026-01-14',
                  'description':
                      'PAGO TARJETA DE CREDITO BANCO NACIONAL DE MEXICO SA',
                  'amount': -100.0,
                  'kind': 'double_entry_in_period',
                },
              ],
            ),
          ], status: 'explained_by_existing_transactions'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Difference'), findsOneWidget);
      expect(find.text(_mxn(-100)), findsOneWidget);
    });

    testWidgets('multi-account results are grouped under account names', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([
          _account([
            _statement(
              status: 'reconciled',
              statementClosing: 1150.0,
              computedClosing: 1150.0,
              difference: 0.0,
            ),
          ]),
          {
            'account_id': 'acct-2',
            'account_name': 'Nu Cajita',
            'currency': 'MXN',
            'status': 'unavailable',
            'statements': [
              _statement(
                status: 'unavailable',
                file: 'NU-ENERO.pdf',
                unavailableReason: 'balance_marker_only',
              ),
            ],
          },
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Banamex Perfiles'), findsOneWidget);
      expect(find.text('Nu Cajita'), findsOneWidget);
      expect(find.text('Balances to the centavo'), findsOneWidget);
      expect(find.text('Not checked'), findsOneWidget);
    });
  });

  group('es-MX', () {
    testWidgets('renders the Spanish copy for every status', (tester) async {
      await tester.pumpWidget(
        _host(locale: const Locale('es'), [
          _account([
            _statement(
              status: 'reconciled',
              file: 'A.pdf',
              statementClosing: 1150.0,
              computedClosing: 1150.0,
              difference: 0.0,
            ),
            _statement(
              status: 'reconciled_after_duplicate_skip',
              file: 'B.pdf',
              statementClosing: 1150.0,
              computedClosing: 1150.0,
              difference: 0.0,
              duplicateRows: 1,
            ),
            _statement(
              status: 'unexplained',
              file: 'C.pdf',
              statementClosing: 1150.0,
              computedClosing: 1100.0,
              difference: 50.0,
            ),
            _statement(
              status: 'unavailable',
              file: 'D.pdf',
              unavailableReason: 'no_running_balance',
            ),
          ], status: 'unexplained'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Revisión del estado de cuenta'), findsOneWidget);
      expect(find.text('Cuadra al centavo'), findsOneWidget);
      expect(
        find.text('Cuadra al omitir los movimientos ya importados'),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 movimiento de este estado ya está en la cuenta'),
        findsOneWidget,
      );
      expect(find.text('Diferencia que no podemos explicar'), findsOneWidget);
      expect(
        find.textContaining('Nada en esta cuenta suma esa diferencia'),
        findsOneWidget,
      );
      expect(find.text('Sin verificar'), findsOneWidget);
      expect(find.textContaining('no trae saldo corriente'), findsOneWidget);
      expect(find.text('Saldo final del estado'), findsAtLeast(1));
    });

    testWidgets('es: the explained sentence keeps its two arguments in the '
        'right slots', (tester) async {
      await tester.pumpWidget(
        _host(locale: const Locale('es'), [
          _account([
            _statement(
              status: 'explained_by_existing_transactions',
              statementClosing: 1150.0,
              computedClosing: 1050.0,
              difference: 100.0,
              candidates: [
                {
                  'transaction_id': 'tx-1',
                  'date': '2026-01-14',
                  'description': 'OXXO GAS',
                  'amount': -60.0,
                  'kind': 'double_entry_in_period',
                },
                {
                  'transaction_id': 'tx-2',
                  'date': '2026-02-03',
                  'description': 'COMISION',
                  'amount': -40.0,
                  'kind': 'misdated_near_period',
                },
              ],
            ),
          ], status: 'explained_by_existing_transactions'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Explicada por movimientos que ya tienes'),
        findsOneWidget,
      );
      // Money in the {difference} slot, the count in the {count} slot — a
      // transposition would put "2" where the money goes.
      expect(
        find.textContaining('difiere por exactamente ${_mxn(100)}'),
        findsOneWidget,
      );
      expect(find.textContaining('el total de 2 movimientos'), findsOneWidget);
      expect(find.text('Movimientos que suman la diferencia'), findsOneWidget);
      expect(find.text('Ya está aquí, no en el estado'), findsNothing);
      expect(
        find.textContaining('Ya está aquí, no en el estado'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Fechado fuera del periodo del estado'),
        findsOneWidget,
      );
    });
  });
}
