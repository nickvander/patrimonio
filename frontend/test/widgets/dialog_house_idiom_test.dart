import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/services/tx_page.dart';
import 'package:patrimonio/theme/fields.dart';
import 'package:patrimonio/theme/palette.dart';
import 'package:patrimonio/widgets/add_loan_dialog.dart';
import 'package:patrimonio/widgets/add_recurring_rule_dialog.dart';
import 'package:patrimonio/widgets/edit_loan_dialog.dart';
import 'package:patrimonio/widgets/record_payment_sheet.dart';
import 'package:patrimonio/widgets/split_transaction_dialog.dart';

/// The 2026-08-02 dialog-consistency sweep standardised one form-field
/// recipe (filled on `tileSurface`, 12px radius, no border) and one
/// presentation rule (bottom sheet on narrow, AlertDialog on wide), but
/// left three panels behind: the split editor, the three lending panels
/// (which carried their own `_decoration` — a `tint(0.03)` fill in a
/// radius-10 hairline box with a teal focus ring), and the recurring-rule
/// dialog (dialog-only at every width).
///
/// These pin the leftovers onto the shared definitions — `theme/fields.dart`
/// and the `open…Panel` width split — so a future edit can't quietly fork a
/// fifth style again. Assertions compare against
/// [houseFieldDecoration]'s own output rather than literals, so the tests
/// follow the helper if the recipe ever changes.

class _FakeApi extends ApiService {
  @override
  Future<TxPage> getTransactions({
    int limit = 50,
    int offset = 0,
    String? currency,
    String? sign,
    String? query,
    bool excludeLinked = false,
  }) async => const TxPage(rows: []);
}

/// Captured inside the pumped tree so the reference decoration resolves
/// against the same `Theme`/`ColorScheme` the widget under test used.
BuildContext? _captured;

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (ctx) {
        _captured = ctx;
        return child;
      },
    ),
  ),
);

/// Every rendered [InputDecoration] in the tree, keyed by label. Reading
/// the mounted [InputDecorator] (rather than the source widget) is what
/// proves the decoration actually reached the field.
Map<String, InputDecoration> _fields(WidgetTester tester) {
  final out = <String, InputDecoration>{};
  for (final d in tester.widgetList<InputDecorator>(
    find.byType(InputDecorator),
  )) {
    final label = d.decoration.labelText;
    if (label != null) out[label] = d.decoration;
  }
  return out;
}

/// Assert [actual] carries the shared house recipe: same fill, same
/// borderless rounded outline, same density as [houseFieldDecoration].
void _expectHouseField(InputDecoration actual, String what) {
  final reference = houseFieldDecoration(_captured!, labelText: 'ref');
  expect(actual.filled, isTrue, reason: '$what should be a filled field');
  expect(actual.isDense, reference.isDense, reason: '$what density');
  expect(actual.fillColor, reference.fillColor, reason: '$what fill colour');
  expect(
    actual.border,
    isA<OutlineInputBorder>()
        .having(
          (b) => b.borderSide,
          '$what border side (house fields are borderless)',
          BorderSide.none,
        )
        .having(
          (b) => b.borderRadius,
          '$what corner radius',
          BorderRadius.circular(kHouseFieldRadius),
        ),
  );
}

SplitTransactionDialog _splitDialog({List<String> categories = const []}) =>
    SplitTransactionDialog(
      parentAmount: 100.0,
      parentCurrency: 'USD',
      parentLabel: 'Costco run',
      parentCategory: 'Groceries',
      usdMxnRate: 17.0,
      targetCurrency: 'USD',
      reportingFormat: NumberFormat.currency(name: 'USD', symbol: r'$'),
      availableCategories: categories,
    );

void main() {
  late AppLocalizations l;

  setUpAll(() async {
    l = await AppLocalizations.delegate.load(const Locale('en'));
  });

  tearDown(() => _captured = null);

  group('split editor is on the house idiom', () {
    testWidgets('its fields use the shared house decoration', (tester) async {
      await tester.pumpWidget(
        _host(_splitDialog(categories: const ['Groceries', 'Household'])),
      );
      await tester.pumpAndSettle();

      final fields = _fields(tester);
      _expectHouseField(fields[l.txSplitDescription]!, 'split description');
      _expectHouseField(fields[l.txSplitAmount]!, 'split amount');
      // The per-row category picker is a DropdownButtonFormField — same
      // recipe, and it only renders when the host passes categories.
      _expectHouseField(fields[l.txCategory]!, 'split row category');
    });

    testWidgets('its shell uses the house card tone and title size', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_splitDialog()));
      await tester.pumpAndSettle();

      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      final theme = Theme.of(_captured!);
      // The tone main.dart's cardTheme uses — what every other house
      // panel's shell (dialog AND sheet) sits on, instead of M3's seeded
      // dialog container.
      expect(
        dialog.backgroundColor,
        BrandPalette.cardSurface(theme.brightness),
      );
      expect(dialog.titleTextStyle, theme.textTheme.titleLarge);
    });

    // The restyle is presentation-only, so the two behaviours with real
    // depth — a quick-split preset and a per-row category override — have
    // to survive it end to end, all the way to the popped payload.
    testWidgets('a preset and a per-row category pick still save through', (
      tester,
    ) async {
      List<Map<String, dynamic>>? popped;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  popped = await showDialog<List<Map<String, dynamic>>>(
                    context: ctx,
                    builder: (_) => _splitDialog(
                      categories: const ['Groceries', 'Household'],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Quick-split preset: 60 / 40 off the tune menu.
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      await tester.tap(find.text('60 / 40'));
      await tester.pumpAndSettle();

      final descFields = find.byType(TextFormField);
      await tester.enterText(descFields.at(0), 'Veggies');
      await tester.enterText(descFields.at(2), 'Batteries');
      await tester.pumpAndSettle();

      // Per-row category pick: override row 0 away from the parent's.
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Household').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, l.txSplitSave));
      await tester.pumpAndSettle();

      expect(popped, isNotNull);
      expect(popped, hasLength(2));
      // The preset's ratio, the typed descriptions and the per-row
      // override all reach the payload.
      expect(popped![0]['description'], 'Veggies');
      expect(popped![0]['amount'], 60.0);
      expect(popped![0]['category'], 'Household');
      expect(popped![1]['description'], 'Batteries');
      expect(popped![1]['amount'], 40.0);
      expect(popped![1]['category'], 'Groceries');
    });
  });

  group('lending panels use the shared house decoration', () {
    testWidgets('AddLoanDialog', (tester) async {
      await tester.pumpWidget(
        _host(
          AddLoanDialog(
            apiService: _FakeApi(),
            people: const [],
            defaultCurrency: 'USD',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fields = _fields(tester);
      _expectHouseField(fields[l.lendFieldBorrowerName]!, 'borrower name');
      _expectHouseField(fields[l.lendFieldAmountLent]!, 'amount lent');
      // The tappable date field is an InputDecorator too — it must carry
      // the same recipe or it reads as a different control.
      _expectHouseField(fields[l.lendFieldLentOn]!, 'lent-on date');
    });

    testWidgets('EditLoanDialog', (tester) async {
      await tester.pumpWidget(
        _host(
          EditLoanDialog(
            apiService: _FakeApi(),
            loan: const {
              'id': 'l1',
              'borrower_name': 'Jose',
              'principal': 30000,
              'currency': 'MXN',
              'interest_type': 'none',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fields = _fields(tester);
      _expectHouseField(fields[l.lendFieldBorrowerName]!, 'borrower name');
      _expectHouseField(fields[l.lendFieldAmountLent]!, 'amount lent');
      _expectHouseField(fields[l.lendFieldPayBackBy]!, 'pay-back-by date');
    });

    testWidgets('RecordPaymentSheet', (tester) async {
      await tester.pumpWidget(
        _host(
          RecordPaymentSheet(
            apiService: _FakeApi(),
            loanId: 'l1',
            currency: 'MXN',
            mode: RecordMode.repayment,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.lendSegCash));
      await tester.pumpAndSettle();

      final fields = _fields(tester);
      _expectHouseField(fields[l.lendFieldAmountReceived]!, 'amount received');
      _expectHouseField(fields[l.lendFieldReceivedOn]!, 'received-on date');
    });
  });

  group('recurring-rule panel', () {
    testWidgets('its fields use the shared house decoration', (tester) async {
      await tester.pumpWidget(
        _host(
          AddRecurringRuleDialog(
            accounts: const [
              {'id': 'a1', 'name': 'Checking', 'currency': 'USD'},
            ],
            apiService: _FakeApi(),
            onCreated: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fields = _fields(tester);
      _expectHouseField(fields[l.dlgTxAmount]!, 'recurring amount');
      _expectHouseField(fields[l.dlgTxDescription]!, 'recurring description');
      _expectHouseField(fields[l.recNextDueDate]!, 'next-due date');
    });

    // The presentation rule the sweep applied to every other form panel
    // (openAddTransactionPanel): sheet under kCompactLayoutBelow, dialog
    // over it. openAddRecurringRulePanel is the one entry point that
    // decides this, so both branches are asserted through it.
    Future<void> pumpOpener(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => openAddRecurringRulePanel(
                  ctx,
                  accounts: const [
                    {'id': 'a1', 'name': 'Checking', 'currency': 'USD'},
                  ],
                  apiService: _FakeApi(),
                  onCreated: () {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('opens as a bottom sheet on a narrow window', (tester) async {
      await pumpOpener(tester, const Size(400, 900));

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      // The sheet's primary action is full-bleed and >=48dp, per the
      // touch-width rule the other sheets follow.
      final save = tester.getSize(
        find.widgetWithText(FilledButton, l.recCreateRule),
      );
      expect(save.height, greaterThanOrEqualTo(48.0));
    });

    testWidgets('opens as a dialog on a wide window', (tester) async {
      await pumpOpener(tester, const Size(1100, 900));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });
}
