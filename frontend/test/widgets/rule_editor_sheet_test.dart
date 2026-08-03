import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/rule_editor_sheet.dart';

// RuleEditorSheet is the surface where a rule can rewrite history, so the
// interlocks are pinned here: the §5.1 prefill ladder, both primary
// actions disabled until a preview LANDS, the confirm dialog restating the
// previewed count, and the apply result reporting its counts and its
// `skipped` honestly (rows edited by hand between preview and apply).

const Map<String, dynamic> _previewPayload = {
  'matched': 37,
  'category_changes': 22,
  'description_changes': 31,
  'skipped_manual': 4,
  'fx_transfer_legs': 0,
  'derived_merchant_key': 'OXXO GAS',
  'samples': [
    {
      'id': 't1',
      'date': '2026-07-14',
      'account_name': 'Banamex',
      'display_description': 'OXXO GAS 4210',
      'old_category': 'Shopping',
      'new_category': 'Transportation',
      'old_description': 'OXXO GAS 4210',
      'new_description': null,
    },
  ],
  'preview_token': 'tok-42',
  'expires_in_seconds': 900,
};

/// House fake pattern: `extends ApiService` + `@override` (the domain
/// endpoints are mixin members, i.e. ordinary virtual methods).
class _FakeRulesApi extends ApiService {
  _FakeRulesApi({this.preview, this.applyResult, this.previewError});

  RulePreview? preview;
  RuleApplyResult? applyResult;
  Object? previewError;

  /// When set, previews block on this instead of resolving.
  Completer<RulePreview>? gate;

  int previewCalls = 0;
  RuleDraft? lastPreviewDraft;
  RuleDraft? createdDraft;
  String? appliedRuleId;
  String? appliedToken;

  @override
  Future<RulePreview> previewRule(RuleDraft draft) {
    previewCalls++;
    lastPreviewDraft = draft;
    final g = gate;
    if (g != null) return g.future;
    if (previewError != null) return Future.error(previewError!);
    return Future.value(preview);
  }

  @override
  Future<UserRule> createRule(RuleDraft draft, {bool active = true}) async {
    createdDraft = draft;
    return UserRule(
      id: 'rule-1',
      matchType: draft.matchType,
      matchValue: draft.matchValue,
      setCategory: draft.setCategory,
      setDescription: draft.setDescription,
      priority: 0,
      active: active,
    );
  }

  @override
  Future<RuleApplyResult> applyRule(String id, String previewToken) async {
    appliedRuleId = id;
    appliedToken = previewToken;
    return applyResult!;
  }
}

Widget _host(
  _FakeRulesApi api, {
  Locale locale = const Locale('en'),
  RuleDraft initial = const RuleDraft(
    matchType: 'contains',
    matchValue: 'OXXO GAS',
    setCategory: 'Transportation',
  ),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => showRuleEditorSheet(
            context,
            api: api,
            initial: initial,
            previewDebounce: Duration.zero,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

/// Open the sheet and let the modal route animate in. Deliberately NOT
/// pumpAndSettle: while a preview is in flight the diff shows a
/// CircularProgressIndicator, which never settles.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

String _normSpace(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => _normSpace(t.data ?? ''))
    .join('\n');

void main() {
  group('prefill ladder (design §5.1)', () {
    test('counterparty_name wins over merchant and description', () {
      final draft = ruleDraftFromTransaction(const {
        'counterparty_name': 'Starbucks',
        'merchant_name': 'STARBUCKS REFORMA',
        'description': 'COMPRA STARBUCKS REFORMA 123',
      });
      expect(draft.matchType, 'contains');
      expect(draft.matchValue, 'Starbucks');
    });

    test('merchant_name is the second rung', () {
      final draft = ruleDraftFromTransaction(const {
        'counterparty_name': '   ',
        'merchant_name': 'STARBUCKS REFORMA',
        'description': 'COMPRA STARBUCKS REFORMA 123',
      });
      expect(draft.matchValue, 'STARBUCKS REFORMA');
    });

    test('description is the fallback', () {
      final draft = ruleDraftFromTransaction(const {
        'description': 'SPEI RECIBIDO BANORTE 0123',
      });
      expect(draft.matchValue, 'SPEI RECIBIDO BANORTE 0123');
    });

    test('actions seed from the effective category and rename override', () {
      final draft = ruleDraftFromTransaction(const {
        'description': 'OXXO GAS',
        'category': 'GENERAL_MERCHANDISE',
        'user_category': 'Transportation',
        'user_description': 'OXXO Gas',
      });
      expect(draft.setCategory, 'Transportation');
      expect(draft.setDescription, 'OXXO Gas');
    });

    test('without a user override the auto category seeds the action', () {
      final draft = ruleDraftFromTransaction(const {
        'description': 'OXXO GAS',
        'category': 'Transportation',
      });
      expect(draft.setCategory, 'Transportation');
      expect(draft.setDescription, isNull);
    });

    test('a draft with no action is invalid — the editor blocks saving', () {
      final draft = ruleDraftFromTransaction(const {'description': 'OXXO GAS'});
      expect(draft.isValid, isFalse);
    });
  });

  testWidgets('both actions stay disabled until a preview lands', (
    tester,
  ) async {
    final api = _FakeRulesApi()..gate = Completer<RulePreview>();
    await tester.pumpWidget(_host(api));
    await _openSheet(tester);

    // Preview in flight: the counts are unknown, so the apply button shows
    // its no-count label and NEITHER action is pressable.
    expect(find.text('Save & apply'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save & apply'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Save rule'),
          )
          .onPressed,
      isNull,
    );

    api.gate!.complete(RulePreview.fromJson(_previewPayload));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(
              FilledButton,
              'Save & apply · changes 22 categories, 31 names',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Save rule'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a failed preview keeps the apply gated', (tester) async {
    final api = _FakeRulesApi(previewError: Exception('preview exploded'));
    await tester.pumpWidget(_host(api));
    await _openSheet(tester);
    await tester.pumpAndSettle();

    expect(_allText(tester), contains('Preview failed: preview exploded'));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save & apply'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'confirm dialog restates the previewed count, then the apply reports '
    'its own counts and the skipped rows',
    (tester) async {
      final api = _FakeRulesApi(
        preview: RulePreview.fromJson(_previewPayload),
        // Deliberately 24 > the previewed 22 category changes: the apply
        // also stamps provenance on matched rows that already showed the
        // target value. The UI reports what actually happened.
        applyResult: const RuleApplyResult(
          updatedCategory: 24,
          updatedDescription: 31,
          skipped: 4,
        ),
      );
      await tester.pumpWidget(_host(api));
      await _openSheet(tester);
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('Save & apply · changes 22 categories, 31 names'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Apply to past transactions?'), findsOneWidget);
      final dialogText = _allText(tester);
      expect(dialogText, contains('37 past transactions match this rule.'));
      expect(dialogText, contains('22 would show a new category'));
      expect(dialogText, contains('31 a new name'));
      expect(
        dialogText,
        contains('Transactions you edited by hand are never touched.'),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      // Created, then applied with the token the preview minted.
      expect(api.createdDraft?.matchValue, 'OXXO GAS');
      expect(api.appliedRuleId, 'rule-1');
      expect(api.appliedToken, 'tok-42');

      final snack = _allText(tester);
      expect(snack, contains('Applied: 24 categories, 31 names updated.'));
      expect(
        snack,
        contains(
          '4 transactions were skipped — they were edited by hand after '
          'the preview.',
        ),
      );
    },
  );

  testWidgets('es: the confirm dialog restates the count in es-MX', (
    tester,
  ) async {
    final api = _FakeRulesApi(
      preview: RulePreview.fromJson(_previewPayload),
      applyResult: const RuleApplyResult(
        updatedCategory: 24,
        updatedDescription: 31,
        skipped: 0,
      ),
    );
    await tester.pumpWidget(_host(api, locale: const Locale('es')));
    await _openSheet(tester);
    await tester.pumpAndSettle();

    await tester.tap(
      find.text('Guardar y aplicar · cambia 22 categorías, 31 nombres'),
    );
    await tester.pumpAndSettle();

    expect(find.text('¿Aplicar a movimientos pasados?'), findsOneWidget);
    expect(
      _allText(tester),
      contains('37 movimientos pasados coinciden con esta regla.'),
    );
  });

  testWidgets('cancelling the confirm dialog applies nothing', (tester) async {
    final api = _FakeRulesApi(
      preview: RulePreview.fromJson(_previewPayload),
      applyResult: const RuleApplyResult(
        updatedCategory: 1,
        updatedDescription: 0,
        skipped: 0,
      ),
    );
    await tester.pumpWidget(_host(api));
    await _openSheet(tester);
    await tester.pumpAndSettle();

    await tester.tap(
      find.text('Save & apply · changes 22 categories, 31 names'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(api.createdDraft, isNull);
    expect(api.appliedRuleId, isNull);
  });

  testWidgets('Save rule is forward-only — it never applies', (tester) async {
    final api = _FakeRulesApi(preview: RulePreview.fromJson(_previewPayload));
    await tester.pumpWidget(_host(api));
    await _openSheet(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();

    expect(api.createdDraft?.matchValue, 'OXXO GAS');
    expect(api.appliedRuleId, isNull);
    expect(
      _allText(tester),
      contains('Rule saved. It applies to new transactions from now on.'),
    );
  });

  // The primary button used to read "Save & apply to {matched} past
  // transactions", which oversold the blast radius: `matched` is only how many
  // rows the rule TOUCHES, and most of those already show the target value
  // (the apply just stamps them rule-managed). The label now leads with what
  // will visibly change — without inventing a combined number the preview
  // doesn't report, and without hiding the matched-vs-applied nuance, which
  // stays in the confirm dialog and the apply snackbar.
  group('apply button leads with the change counts, honestly', () {
    Map<String, dynamic> payload({
      required int matched,
      required int categoryChanges,
      required int descriptionChanges,
    }) => {
      ..._previewPayload,
      'matched': matched,
      'category_changes': categoryChanges,
      'description_changes': descriptionChanges,
    };

    testWidgets('a category-only rule counts transactions, not matches', (
      tester,
    ) async {
      final api = _FakeRulesApi(
        preview: RulePreview.fromJson(
          payload(matched: 37, categoryChanges: 22, descriptionChanges: 0),
        ),
      );
      await tester.pumpWidget(_host(api));
      await _openSheet(tester);
      await tester.pumpAndSettle();

      // 22, not 37: with a single action the change count IS the number of
      // transactions whose displayed value moves.
      expect(
        find.text('Save & apply · changes 22 transactions'),
        findsOneWidget,
      );
      // The matched count is still on screen (the preview line reports it and
      // the confirm dialog explains it) — it just no longer leads the button.
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.textContaining('37'),
        ),
        findsNothing,
      );
      expect(_allText(tester), contains('Matches 37'));
    });

    testWidgets('es-MX: the same single-action label is localized', (
      tester,
    ) async {
      final api = _FakeRulesApi(
        preview: RulePreview.fromJson(
          payload(matched: 37, categoryChanges: 22, descriptionChanges: 0),
        ),
      );
      await tester.pumpWidget(_host(api, locale: const Locale('es')));
      await _openSheet(tester);
      await tester.pumpAndSettle();

      expect(
        find.text('Guardar y aplicar · cambia 22 movimientos'),
        findsOneWidget,
      );
    });

    testWidgets('a rename-only rule counts the renames', (tester) async {
      final api = _FakeRulesApi(
        preview: RulePreview.fromJson(
          payload(matched: 12, categoryChanges: 0, descriptionChanges: 5),
        ),
      );
      await tester.pumpWidget(_host(api));
      await _openSheet(tester);
      await tester.pumpAndSettle();

      expect(
        find.text('Save & apply · changes 5 transactions'),
        findsOneWidget,
      );
    });

    testWidgets('the singular branch reads as one transaction', (tester) async {
      final api = _FakeRulesApi(
        preview: RulePreview.fromJson(
          payload(matched: 9, categoryChanges: 1, descriptionChanges: 0),
        ),
      );
      await tester.pumpWidget(_host(api));
      await _openSheet(tester);
      await tester.pumpAndSettle();

      expect(find.text('Save & apply · changes 1 transaction'), findsOneWidget);
    });

    testWidgets(
      'a two-action rule names BOTH counts rather than inventing a union',
      (tester) async {
        final api = _FakeRulesApi(
          preview: RulePreview.fromJson(
            payload(matched: 37, categoryChanges: 22, descriptionChanges: 31),
          ),
        );
        await tester.pumpWidget(_host(api));
        await _openSheet(tester);
        await tester.pumpAndSettle();

        // A row can be in both sets, and the preview reports no combined
        // count — so neither 53 (a sum) nor 31 (a guess) is claimed.
        expect(
          find.text('Save & apply · changes 22 categories, 31 names'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'nothing to change: the label makes no claim, but the apply stays '
      'available because it still marks matched rows rule-managed',
      (tester) async {
        final api = _FakeRulesApi(
          preview: RulePreview.fromJson(
            payload(matched: 37, categoryChanges: 0, descriptionChanges: 0),
          ),
        );
        await tester.pumpWidget(_host(api));
        await _openSheet(tester);
        await tester.pumpAndSettle();

        expect(find.text('Save & apply'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save & apply'),
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('no matches at all keeps the apply disabled', (tester) async {
      final api = _FakeRulesApi(
        preview: RulePreview.fromJson(
          payload(matched: 0, categoryChanges: 0, descriptionChanges: 0),
        ),
      );
      await tester.pumpWidget(_host(api));
      await _openSheet(tester);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save & apply'),
            )
            .onPressed,
        isNull,
      );
    });
  });

  testWidgets('the previewed draft carries the editor state verbatim', (
    tester,
  ) async {
    final api = _FakeRulesApi(preview: RulePreview.fromJson(_previewPayload));
    await tester.pumpWidget(_host(api));
    await _openSheet(tester);
    await tester.pumpAndSettle();

    expect(api.previewCalls, 1);
    expect(api.lastPreviewDraft?.matchType, 'contains');
    expect(api.lastPreviewDraft?.matchValue, 'OXXO GAS');
    expect(api.lastPreviewDraft?.setCategory, 'Transportation');

    // Switching the matcher re-previews with the new definition — the
    // token on screen must always belong to what the user is looking at.
    await tester.tap(find.text('Exact'));
    await tester.pumpAndSettle();
    expect(api.previewCalls, 2);
    expect(api.lastPreviewDraft?.matchType, 'exact');
  });
}
