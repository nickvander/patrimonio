import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/rule_preview_diff.dart';

// The dry-run diff is the rules engine's entire safety story, so its copy
// is pinned in BOTH locales from a canned `POST /rules/preview` payload:
// the count line, the before→after sample rows, the skipped-as-manual
// line, the preview-vs-apply provenance caveat, and the FX-transfer
// warning (DEC-028 chose allow + warn, which makes the banner the guard).

Widget _host(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// Collapse NBSP/NNBSP so es assertions don't pin exact codepoints.
String _normSpace(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => _normSpace(t.data ?? ''))
    .join('\n');

/// Verbatim shape of the backend's PreviewResponse (api/rules.rs).
const Map<String, dynamic> _payload = {
  'matched': 37,
  'category_changes': 22,
  'description_changes': 31,
  'skipped_manual': 4,
  'fx_transfer_legs': 1,
  'derived_merchant_key': 'OXXO GAS',
  'samples': [
    {
      'id': 't1',
      'date': '2026-07-14',
      'account_name': 'Banamex Perfiles',
      'display_description': 'OXXO GAS 4210 CDMX',
      'old_category': 'Shopping',
      'new_category': 'Transportation',
      'old_description': 'OXXO GAS 4210 CDMX',
      'new_description': 'OXXO Gas',
    },
    {
      'id': 't2',
      'date': '2026-06-02',
      'account_name': 'Nu',
      'display_description': 'OXXO GAS 7781',
      'old_category': null,
      'new_category': 'Transportation',
      'old_description': 'OXXO GAS 7781',
      'new_description': null,
    },
  ],
  'preview_token': 'tok-1',
  'expires_in_seconds': 900,
};

void main() {
  final preview = RulePreview.fromJson(_payload);

  testWidgets('en: counts, samples, skipped-manual and FX warning render', (
    tester,
  ) async {
    await tester.pumpWidget(_host(RulePreviewDiff(preview: preview)));
    await tester.pumpAndSettle();
    final text = _allText(tester);

    // The count line keeps matched / category changes / name changes in
    // that order — three same-typed ints, the transposition-prone shape.
    expect(text, contains('Matches 37 · changes 22 categories, 31 names'));
    expect(text, contains('4 skipped as manual edits'));
    // The preview-vs-apply caveat: the apply also stamps provenance on
    // matched rows that already show the target value, so its counts can
    // exceed these. Said out loud, not implied away.
    expect(
      text,
      contains(
        'Applying also marks matched transactions that already show these '
        'values as rule-managed, so the applied count can be higher than '
        'the changes above.',
      ),
    );
    expect(
      text,
      contains(
        '1 matched transaction is a leg of a confirmed currency transfer.',
      ),
    );

    // before → after, per field, per sample row.
    expect(text, contains('OXXO GAS 4210 CDMX'));
    expect(text, contains('Shopping'));
    expect(text, contains('Transportation'));
    expect(text, contains('OXXO Gas'));
    expect(text, contains('Category'));
    expect(text, contains('Name'));
    // A row with no current category shows the em-dash placeholder, not
    // an empty gap.
    expect(text, contains('—'));
  });

  testWidgets('es: the same diff renders in es-MX', (tester) async {
    await tester.pumpWidget(
      _host(RulePreviewDiff(preview: preview), locale: const Locale('es')),
    );
    await tester.pumpAndSettle();
    final text = _allText(tester);

    expect(
      text,
      contains('Coincide con 37 · cambia 22 categorías y 31 nombres'),
    );
    expect(text, contains('4 omitidos por ser ediciones manuales'));
    expect(
      text,
      contains(
        'Al aplicar también se marcan como gestionados por la regla los '
        'movimientos que ya muestran estos valores',
      ),
    );
    expect(
      text,
      contains(
        '1 movimiento coincidente es parte de una transferencia de divisas '
        'confirmada.',
      ),
    );
    expect(text, contains('Categoría'));
    expect(text, contains('Nombre'));
    expect(text, contains('Transportation'));
  });

  testWidgets('no FX legs: the transfer warning is absent', (tester) async {
    final clean = RulePreview.fromJson({..._payload, 'fx_transfer_legs': 0});
    await tester.pumpWidget(_host(RulePreviewDiff(preview: clean)));
    await tester.pumpAndSettle();
    expect(_allText(tester), isNot(contains('currency transfer')));
  });

  testWidgets('no manual skips: the skipped line is absent', (tester) async {
    final clean = RulePreview.fromJson({..._payload, 'skipped_manual': 0});
    await tester.pumpWidget(_host(RulePreviewDiff(preview: clean)));
    await tester.pumpAndSettle();
    expect(_allText(tester), isNot(contains('skipped as manual')));
  });

  testWidgets('matches but nothing visible changes says so', (tester) async {
    final noop = RulePreview.fromJson({
      ..._payload,
      'category_changes': 0,
      'description_changes': 0,
      'samples': <dynamic>[],
    });
    await tester.pumpWidget(_host(RulePreviewDiff(preview: noop)));
    await tester.pumpAndSettle();
    expect(_allText(tester), contains('Nothing would look different'));
  });

  testWidgets('loading with no preview yet shows the progress line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const RulePreviewDiff(preview: null, loading: true)),
    );
    await tester.pump();
    expect(_allText(tester), contains('Checking your history…'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a failed preview surfaces the server message', (tester) async {
    await tester.pumpWidget(
      _host(
        const RulePreviewDiff(
          preview: null,
          error: 'match_value can\'t be empty',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _allText(tester),
      contains("Preview failed: match_value can't be empty"),
    );
  });
}
