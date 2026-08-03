import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/connected_segments.dart';
import 'package:patrimonio/widgets/quick_entry_sheet.dart';

// The quick-entry sheet writes real money rows with no confirmation step,
// so the things pinned here are the ones a bug would corrupt silently:
// the STORAGE SIGN (spending must reach the API negative — the app
// convention, the opposite of Plaid's raw sign), the exact payload, the
// derived-and-overridable defaults, the Undo that deletes exactly the row
// it wrote, and the both-locales rendering of the confirmation.

/// House fake pattern: `extends ApiService` + `@override` (the domain
/// endpoints are mixin members, i.e. ordinary virtual methods). Nothing
/// here touches HTTP.
class _FakeQuickApi extends ApiService {
  final List<Map<String, dynamic>> creates = <Map<String, dynamic>>[];
  final List<String> deleted = <String>[];

  /// Id handed back for the next create; null models a server response
  /// with no parseable id (the row saved, the Undo handle did not).
  String? nextId = 'tx-1';
  Object? createError;
  Object? deleteError;

  @override
  Future<String?> createManualTransactionReturningId({
    required String accountId,
    required DateTime date,
    required String description,
    required double amount,
    required String currency,
    String? category,
    String? notes,
  }) async {
    creates.add({
      'accountId': accountId,
      'date': date,
      'description': description,
      'amount': amount,
      'currency': currency,
      'category': category,
      'notes': notes,
    });
    if (createError != null) throw createError!;
    return nextId;
  }

  @override
  Future<void> deleteTransaction(String txId) async {
    deleted.add(txId);
    if (deleteError != null) throw deleteError!;
  }
}

const _accounts = [
  {
    'id': 'acct-cash',
    'name': 'Efectivo',
    'currency': 'MXN',
    'account_type': 'depository',
  },
  {
    'id': 'acct-usd',
    'name': 'Chase',
    'currency': 'USD',
    'account_type': 'depository',
  },
];

/// One manual row on the MXN account, newer than the USD one, so
/// "last used" resolves to acct-cash and the chips carry its categories.
const _recent = [
  {
    'account_id': 'acct-usd',
    'source': 'manual',
    'date': '2026-07-20',
    'created_at': '2026-07-20T10:00:00Z',
    'user_category': 'Gasolina',
  },
  {
    'account_id': 'acct-cash',
    'source': 'manual',
    'date': '2026-08-01',
    'created_at': '2026-08-01T10:00:00Z',
    'user_category': 'Tacos',
  },
];

String _normSpace(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

Widget _host(
  _FakeQuickApi api, {
  Locale locale = const Locale('en'),
  List<dynamic> accounts = _accounts,
  List<dynamic> recentTransactions = _recent,
  List<String> categorySuggestions = const [],
  VoidCallback? onFullForm,
  VoidCallback? onCreated,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => openQuickEntrySheet(
            context,
            accounts: accounts,
            apiService: api,
            onCreated: onCreated ?? () {},
            recentTransactions: recentTransactions,
            categorySuggestions: categorySuggestions,
            onFullForm: onFullForm,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _tapChip(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Every text currently on screen, whitespace-normalized (es puts NBSPs
/// inside its money strings).
String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => _normSpace(t.data ?? ''))
    .join('\n');

void main() {
  group('sign convention (the thing a bug corrupts silently)', () {
    testWidgets('"Spent" reaches the API as a NEGATIVE amount', (tester) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180.50');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      expect(api.creates, hasLength(1));
      // NOT 180.50 — the app stores outflow negative (see the doc comment
      // on ApiService.createManualTransaction).
      expect(api.creates.single['amount'], -180.50);
    });

    testWidgets('"Received" reaches the API as a POSITIVE amount', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.tap(find.text('Received'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '180.50');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      expect(api.creates.single['amount'], 180.50);
    });

    testWidgets('the sheet opens on Spent, so the default is an outflow', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      final segments = tester.widget<ConnectedSegments<bool>>(
        find.byType(ConnectedSegments<bool>),
      );
      expect(segments.selected, isTrue);
      expect(find.text('Spent'), findsOneWidget);
    });

    testWidgets('a zero or empty amount is rejected before any call', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await _save(tester, 'Save');
      expect(api.creates, isEmpty);
      expect(find.text('Enter an amount'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '0');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');
      expect(api.creates, isEmpty);
      expect(find.text('Enter a positive amount'), findsOneWidget);
    });
  });

  group('capture flow', () {
    testWidgets('a full capture posts the exact payload', (tester) async {
      final api = _FakeQuickApi();
      var created = 0;
      await tester.pumpWidget(_host(api, onCreated: () => created++));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await _save(tester, 'Save');

      expect(api.creates, hasLength(1));
      final payload = api.creates.single;
      expect(payload['accountId'], 'acct-cash');
      expect(payload['amount'], -180.0);
      // Currency follows the account, never a global default.
      expect(payload['currency'], 'MXN');
      expect(payload['category'], 'Tacos');
      // No note typed → the category names the row.
      expect(payload['description'], 'Tacos');
      final date = payload['date'] as DateTime;
      final now = DateTime.now();
      expect(date.year, now.year);
      expect(date.month, now.month);
      expect(date.day, now.day);
      expect(created, 1);
    });

    testWidgets('a typed note becomes the description', (tester) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '42');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await tester.enterText(
        find.widgetWithText(TextField, 'Note (optional)'),
        'OXXO Reforma',
      );
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      expect(api.creates.single['description'], 'OXXO Reforma');
      expect(api.creates.single['category'], 'Tacos');
    });

    testWidgets('no category and no note falls back to "Cash"', (tester) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '42');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      expect(api.creates.single['category'], isNull);
      expect(api.creates.single['description'], 'Cash');
    });

    testWidgets('"Other…" accepts a free-typed category', (tester) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '42');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Other…');
      await tester.enterText(
        find.widgetWithText(TextField, 'Category (optional)'),
        'Pulquería',
      );
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      expect(api.creates.single['category'], 'Pulquería');
    });

    testWidgets('the sheet stays open and takes a second entry', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await _save(tester, 'Save');

      // No navigation: the sheet is still up and the amount is cleared
      // for the next expense, with the account/category still set.
      expect(find.byType(QuickEntrySheet), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(TextFormField),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        isEmpty,
      );

      await tester.enterText(find.byType(TextFormField), '95');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');
      expect(api.creates, hasLength(2));
      expect(api.creates[1]['amount'], -95.0);
      expect(api.creates[1]['category'], 'Tacos');
    });

    testWidgets('a failed save surfaces the error and offers no Undo', (
      tester,
    ) async {
      final api = _FakeQuickApi()..createError = Exception('Network down');
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      expect(find.text('Network down'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });
  });

  group('amount-first entry', () {
    testWidgets('the amount field is focused with a numeric keypad', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);

      final amount = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TextFormField),
          matching: find.byType(TextField),
        ),
      );
      expect(amount.focusNode!.hasFocus, isTrue);
      expect(
        amount.keyboardType,
        const TextInputType.numberWithOptions(decimal: true),
      );
    });
  });

  group('defaults are derived AND overridable', () {
    testWidgets('the account defaults to the last one manually used', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);

      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(dropdown.initialValue, 'acct-cash');
      // The derivation is stated, not silent.
      expect(find.text('Last used'), findsOneWidget);
      // …and so is the currency it implies.
      expect(_allText(tester), contains('MXN '));
    });

    testWidgets(
      'with no manual history it falls back to the first non-credit account',
      (tester) async {
        final api = _FakeQuickApi();
        await tester.pumpWidget(
          _host(
            api,
            accounts: const [
              {
                'id': 'acct-card',
                'name': 'Amex',
                'currency': 'USD',
                'account_type': 'credit',
              },
              ..._accounts,
            ],
            recentTransactions: const [],
          ),
        );
        await _open(tester);

        final dropdown = tester.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        );
        expect(dropdown.initialValue, 'acct-cash');
        // Nothing was derived from history, so nothing claims to be.
        expect(find.text('Last used'), findsNothing);
      },
    );

    testWidgets('changing the account changes the currency and the payload', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chase').last);
      await tester.pumpAndSettle();

      // The "Last used" caption cannot survive a hand-picked account.
      expect(find.text('Last used'), findsNothing);
      expect(_allText(tester), contains('USD '));

      await tester.enterText(find.byType(TextFormField), '20');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');
      expect(api.creates.single['accountId'], 'acct-usd');
      expect(api.creates.single['currency'], 'USD');
    });

    testWidgets('category chips are recency-ordered, not alphabetical', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(
        _host(api, categorySuggestions: const ['Abarrotes']),
      );
      await _open(tester);

      final labels = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .map((c) => (c.label as Text).data)
          .toList();
      // Tacos (2026-08-01) before Gasolina (2026-07-20), then the
      // all-source fallback, then the free-text escape hatch.
      expect(labels, ['Tacos', 'Gasolina', 'Abarrotes', 'Other…']);
    });

    testWidgets('the date defaults to today and says so', (tester) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('re-tapping the selected chip clears the category', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '42');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await _tapChip(tester, 'Tacos');
      await _save(tester, 'Save');

      expect(api.creates.single['category'], isNull);
    });
  });

  group('undo', () {
    testWidgets('deletes exactly the row it just wrote and restores it', (
      tester,
    ) async {
      final api = _FakeQuickApi()..nextId = 'tx-99';
      var created = 0;
      await tester.pumpWidget(_host(api, onCreated: () => created++));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await _save(tester, 'Save');
      expect(created, 1);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(api.deleted, ['tx-99']);
      expect(find.text('Entry removed'), findsOneWidget);
      // One Undo per action: the affordance is gone once used.
      expect(find.text('Undo'), findsNothing);
      // The host is told the server changed again.
      expect(created, 2);
      // The typed amount comes back so a mistyped entry is a correction.
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(TextFormField),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '180',
      );
    });

    testWidgets('no Undo is offered when the response carried no id', (
      tester,
    ) async {
      final api = _FakeQuickApi()..nextId = null;
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');

      // The write SUCCEEDED — only the handle is missing.
      expect(api.creates, hasLength(1));
      expect(_allText(tester), contains('Saved'));
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('a failed undo says so and keeps the retry', (tester) async {
      final api = _FakeQuickApi()..deleteError = Exception('nope');
      await tester.pumpWidget(_host(api));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _save(tester, 'Save');
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't remove that entry — it's still saved."),
        findsOneWidget,
      );
      expect(find.text('Undo'), findsOneWidget);
    });
  });

  group('confirmation string, both locales', () {
    // qeSaved takes two same-typed args, so a gen-l10n placeholder
    // transposition would compile and only show up as "Saved Tacos ·
    // -MX$180.00". Pinned in en and es.
    Future<String> capture(WidgetTester tester, Locale locale) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api, locale: locale));
      await _open(tester);
      await tester.enterText(find.byType(TextFormField), '180');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await _save(tester, locale.languageCode == 'es' ? 'Guardar' : 'Save');
      return _allText(tester);
    }

    testWidgets('en states the amount first, then the label', (tester) async {
      final text = await capture(tester, const Locale('en'));
      final money = _normSpace(formatCurrencyAmount(-180.0, 'MXN'));
      expect(text, contains('Saved $money · Tacos'));
    });

    testWidgets('es states the amount first, then the label', (tester) async {
      final text = await capture(tester, const Locale('es'));
      final money = _normSpace(formatCurrencyAmount(-180.0, 'MXN'));
      expect(text, contains('Guardado $money · Tacos'));
      // The whole sheet is localized, not just the confirmation.
      expect(text, contains('Captura rápida'));
      expect(text, contains('Gasté'));
    });
  });

  group('layout', () {
    testWidgets('no overflow at a 360px phone width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 690));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      expect(tester.takeException(), isNull);
      // …and still no overflow once the confirmation strip appears.
      await tester.enterText(find.byType(TextFormField), '1234.56');
      await tester.pumpAndSettle();
      await _tapChip(tester, 'Tacos');
      await _save(tester, 'Save');
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at a 320px phone width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api, locale: const Locale('es')));
      await _open(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the form is capped, not stretched, on a desktop width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      expect(tester.takeException(), isNull);
      // The primary action must not become a 1400px banner.
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Save')).width,
        lessThanOrEqualTo(520),
      );
    });
  });

  group('escape hatch', () {
    testWidgets('"More options" closes the sheet and hands off', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      var handedOff = 0;
      await tester.pumpWidget(_host(api, onFullForm: () => handedOff++));
      await _open(tester);
      await tester.tap(find.text('More options'));
      await tester.pumpAndSettle();

      expect(handedOff, 1);
      expect(find.byType(QuickEntrySheet), findsNothing);
    });

    testWidgets('the hand-off is hidden when the host offers none', (
      tester,
    ) async {
      final api = _FakeQuickApi();
      await tester.pumpWidget(_host(api));
      await _open(tester);
      expect(find.text('More options'), findsNothing);
    });
  });

  testWidgets('an account-less user is told, and cannot save', (tester) async {
    final api = _FakeQuickApi();
    await tester.pumpWidget(
      _host(api, accounts: const [], recentTransactions: const []),
    );
    await _open(tester);
    expect(
      find.text(
        'You need at least one account before you can add a transaction.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
