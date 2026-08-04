import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart' show moneyFormat;
import 'package:patrimonio/widgets/loan_detail_sheet.dart';

// Regression: the loan detail sheet decided BOTH of its schedule branches from
// `MediaQuery.sizeOf(context).width` — whether a longer amortization table
// renders inline or collapses behind a disclosure (`< 720`), and whether the
// Interest + Principal-balance columns are dropped (`< 520`).
//
// This is a *modal bottom sheet*: Material 3 caps it at 640dp wide and centres
// it, so the sheet's width is exactly the width in the app with the LEAST
// correlation to the window. On a 1440dp desktop the screen said "1440" while
// the table had ~590dp; on a 700dp window the screen said "phone" while the
// sheet was that same 640dp and the schedule collapsed for no reason. The house
// rule (skill §4/§5) is that a width branch reads the widget's OWN
// `LayoutBuilder` constraint.
//
// Both directions are pinned here, and — because the wrong branch HIDES the
// user's schedule rather than merely restyling them — each case also asserts
// the schedule data itself.

const _currency = 'USD';

/// Five generated installments: more than the ≤3 "short schedule" that is
/// always shown inline, so the collapse branch is live.
List<Map<String, dynamic>> _installments() => [
  for (var i = 1; i <= 5; i++)
    {
      'id': 'p$i',
      'installment_number': i,
      'due_date': '2026-0$i-15',
      'scheduled_amount': 1000.0,
      'scheduled_principal': 900.0,
      'scheduled_interest': 100.0,
      'status': 'scheduled',
      'paid_amount': null,
    },
];

/// Canned loan payments/suggestions; nothing touches the network.
class _FakeApiService extends ApiService {
  @override
  Future<List<dynamic>> getLoanPayments(String loanId) async => _installments();

  @override
  Future<List<dynamic>> getLoanSuggestions(String loanId, String kind) async =>
      const <dynamic>[];
}

Map<String, dynamic> _loan() => {
  'id': 'loan-1',
  'borrower_name': 'Ana',
  'principal': 4500.0,
  'currency': _currency,
  'term_months': 5,
  'payment_frequency': 'monthly',
  'status': 'active',
  // Already linked, so the disbursement section stays compact.
  'disbursement_tx_id': 'tx-1',
};

/// Hosts the sheet at an explicit width, INDEPENDENT of the window: the
/// `OverflowBox` hands it a tight [sheetWidth] whether that is narrower or
/// wider than the surface. Decoupling the two is the whole point — Flutter's
/// own modal-sheet host does exactly this (a 640dp `ConstrainedBox` centred on
/// an arbitrarily wide window).
Widget _host({required double sheetWidth}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: 2000,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: sheetWidth,
          maxWidth: sheetWidth,
          child: LoanDetailSheet(
            apiService: _FakeApiService(),
            loan: _loan(),
            onMutated: () {},
          ),
        ),
      ),
    ),
  ),
);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String _money(num v) => moneyFormat(_currency).format(v);

void main() {
  group('LoanDetailSheet — schedule branches off the sheet constraint', () {
    testWidgets('a narrow sheet on a WIDE window collapses + drops columns', (
      tester,
    ) async {
      // 380dp of sheet on a 1400dp window. The MediaQuery version read 1400
      // here and rendered six columns into ~350dp of table.
      _useSurface(tester, const Size(1400, 2000));
      await tester.pumpWidget(_host(sheetWidth: 380));
      await tester.pumpAndSettle();

      final l = await AppLocalizations.delegate.load(const Locale('en'));

      // The long schedule is behind the count-aware disclosure...
      expect(
        find.text(l.lendViewInstallments(5)),
        findsOneWidget,
        reason: 'narrow sheet collapses a >3-row schedule behind a tap',
      );
      expect(
        find.text(l.lendScheduleColPayment),
        findsNothing,
        reason: 'table is collapsed until the disclosure is tapped',
      );

      // ...and one tap brings it back — the data is reachable, not gone.
      await tester.tap(find.text(l.lendViewInstallments(5)));
      await tester.pumpAndSettle();

      expect(find.text(l.lendScheduleColPayment), findsOneWidget);
      expect(
        find.text(l.lendScheduleColInterest),
        findsNothing,
        reason: 'narrow drops the Interest column',
      );
      expect(
        find.text(l.lendScheduleColBalance),
        findsNothing,
        reason: 'narrow drops the Principal-balance column',
      );

      // The dropped columns fold into each row's subtitle, so no figure is
      // lost: row 1 leaves 4500 - 900 = 3600 of principal and charges 100.
      expect(
        find.text(l.lendScheduleRowMeta(_money(3600), _money(100))),
        findsOneWidget,
        reason: 'dropped Interest/Balance survive as the row subtitle',
      );
      // All five installments render their payment amount.
      expect(find.text(_money(1000)), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide sheet on a SMALL window renders the full table', (
      tester,
    ) async {
      // The inverse: a 640dp sheet (Material 3's cap) on a 420dp window — the
      // MediaQuery version read 420 and both collapsed the table AND dropped
      // two columns from a sheet with 590dp of room.
      _useSurface(tester, const Size(420, 2000));
      await tester.pumpWidget(_host(sheetWidth: 640));
      await tester.pumpAndSettle();

      final l = await AppLocalizations.delegate.load(const Locale('en'));

      expect(
        find.text(l.lendViewInstallments(5)),
        findsNothing,
        reason: 'a wide sheet shows the schedule inline, no disclosure',
      );
      expect(find.text(l.lendScheduleColPayment), findsOneWidget);
      expect(
        find.text(l.lendScheduleColInterest),
        findsOneWidget,
        reason: 'wide keeps the Interest column',
      );
      expect(
        find.text(l.lendScheduleColBalance),
        findsOneWidget,
        reason: 'wide keeps the Principal-balance column',
      );
      // Full columns => the running balance is its own cell, not a subtitle.
      expect(
        find.text(l.lendScheduleRowMeta(_money(3600), _money(100))),
        findsNothing,
      );
      expect(find.text(_money(3600)), findsOneWidget);
      expect(find.text(_money(1000)), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the branch flips at the sheet width, not the window', (
      tester,
    ) async {
      // Same window either side of the flip; only the sheet's own width moves.
      // The table sits inside the sheet's ListView padding (24 a side at this
      // window), so the breakpoint lands at kScheduleNarrowWidth + 48.
      _useSurface(tester, const Size(1400, 2000));
      final l = await AppLocalizations.delegate.load(const Locale('en'));

      await tester.pumpWidget(_host(sheetWidth: kScheduleNarrowWidth + 47));
      await tester.pumpAndSettle();
      expect(
        find.text(l.lendViewInstallments(5)),
        findsOneWidget,
        reason: '519dp of table is narrow',
      );

      await tester.pumpWidget(_host(sheetWidth: kScheduleNarrowWidth + 48));
      await tester.pumpAndSettle();
      expect(
        find.text(l.lendViewInstallments(5)),
        findsNothing,
        reason: '520dp of table is wide enough for the inline table',
      );
      expect(find.text(l.lendScheduleColBalance), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // The sheet's 16/24 padding was the last `MediaQuery` read in this file. It
  // could not simply move onto the sheet's own width against the house ~720
  // card breakpoint: M3 caps a modal bottom sheet at 640dp, so this surface is
  // NEVER 720 wide and every desktop window would have silently dropped from
  // 24px to the touch padding it has never had.
  //
  // It is therefore retuned deliberately onto [kScheduleNarrowWidth], the
  // breakpoint this file already owns, so the sheet has exactly two layouts
  // rather than three. Windows in the 520–720px band (sheet 520–640) move
  // from 16px to 24px; below 520 and at/above 720 nothing changes.
  group(
    'LoanDetailSheet — padding is retuned to the sheet\'s own breakpoint',
    () {
      /// The sheet's outer padding — the `ListView.padding` the sheet body
      /// scrolls inside (`EdgeInsets.fromLTRB(pad, 16, pad, 32)`).
      EdgeInsets outerPadding(WidgetTester tester) =>
          tester.widget<ListView>(find.byType(ListView).first).padding
              as EdgeInsets;

      testWidgets('a 640dp sheet keeps 24px on ANY window', (tester) async {
        // The M3 cap. Pinned at a window that used to say "phone" (700) — the
        // whole point of the retune.
        _useSurface(tester, const Size(700, 2000));
        await tester.pumpWidget(_host(sheetWidth: 640));
        await tester.pumpAndSettle();
        expect(outerPadding(tester).left, 24.0);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a phone-width sheet still gets 16px on a WIDE window', (
        tester,
      ) async {
        _useSurface(tester, const Size(1400, 2000));
        await tester.pumpWidget(_host(sheetWidth: 390));
        await tester.pumpAndSettle();
        expect(outerPadding(tester).left, 16.0);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
