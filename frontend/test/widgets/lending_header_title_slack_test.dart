import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/lending_tab.dart';

/// D4 regression: the lending card header was `Flexible(title)` followed by
/// `const Spacer()`. Both default to flex 1, so the row's free space was
/// split 50/50 and the title was squeezed to half of it — "Money I've lent"
/// truncated to "Money I'…" at phone width while the same row still had
/// ~150px of empty space. The header then no longer said whether the card
/// is money lent or money owed. The title is `Expanded` now (and IS the
/// gap-filler, so the Spacer is gone), which hands it all the slack; it
/// still ellipsizes when the room genuinely runs out.
class _FakeApiService extends ApiService {
  _FakeApiService({this.loans = const []});

  final List<dynamic> loans;

  @override
  Future<List<dynamic>> getLoans() async => loans;

  @override
  Future<List<dynamic>> getLoanPeople() async => const [];

  @override
  Future<Map<String, dynamic>> getLoansSummary({
    bool forceRefresh = false,
  }) async => const {
    'active_count': 1,
    'total_lent': 0,
    'total_outstanding': 0,
  };

  @override
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async => const {
    'total_interest': 0,
    'total_principal': 0,
  };
}

/// The header title as rendered, asserted to be the WHOLE string: `find.text`
/// matches the widget's `data`, which stays intact even when the paragraph
/// paints an ellipsis — so the check has to be on the laid-out paragraph.
void _expectTitleNotTruncated(WidgetTester tester, String title) {
  final finder = find.text(title);
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '"$title" was ellipsized',
  );
  final intrinsic = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
  )..layout();
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(intrinsic.width - 0.5),
    reason:
        'title box is ${paragraph.size.width}px but "$title" needs '
        '${intrinsic.width}px — it is being squeezed, not laid out',
  );
  intrinsic.dispose();
}

Future<void> _pumpLendingTab(
  WidgetTester tester, {
  required Locale locale,
  required Size size,
  List<dynamic> loans = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LendingTab(
          apiService: _FakeApiService(loans: loans),
          targetCurrency: 'USD',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const titles = {'en': "Money I've lent", 'es': 'Dinero que presté'};

  // A loan that has earned interest, so the header also carries the
  // interest-report button + the CSV menu — the crowded case the original
  // Flexible was added for.
  const interestBearingLoan = <String, dynamic>{
    'id': '1',
    'borrower_name': 'Alice',
    'principal': 1000.0,
    'outstanding': 1000.0,
    'total_repaid': 0.0,
    'interest_earned': 50.0,
    'currency': 'USD',
    'status': 'active',
    'origination_date': '2026-01-01',
  };

  for (final entry in titles.entries) {
    testWidgets('lending header title renders in full at 390 (${entry.key})', (
      tester,
    ) async {
      await _pumpLendingTab(
        tester,
        locale: Locale(entry.key),
        size: const Size(390, 900),
      );
      expect(tester.takeException(), isNull);
      _expectTitleNotTruncated(tester, entry.value);
    });

    testWidgets(
      'lending header title keeps its slack beside the action cluster '
      '(${entry.key})',
      (tester) async {
        await _pumpLendingTab(
          tester,
          locale: Locale(entry.key),
          size: const Size(600, 900),
          loans: const [interestBearingLoan],
        );
        _expectTitleNotTruncated(tester, entry.value);
      },
    );
  }
}
