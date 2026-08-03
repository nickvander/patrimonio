// Hit-region contract for the AppBar's reporting-currency control.
//
// A live-rig sweep reported an "invisible hit region" of roughly
// x 264-390, y 56-150 (at 390x844) that toggled the reporting currency on
// tap regardless of what was painted there, making the Cash flow "This
// year" period chip (rect x 286-374, y 72-116) unusable. That claim does
// not reproduce — see the assertions below — but the class of bug it
// describes (a tappable control whose hit box outlives its paint, so a tap
// meant for the body silently re-denominates every figure on screen) is
// exactly what the rest of the suite could not see: every other test
// exercises widgets in isolation, where the app bar and the tab body never
// share a coordinate space.
//
// So these tests pin the contract on the REAL screen, in real coordinates:
// the currency control must be hit-testable only inside its own laid-out
// box in the app bar, and the period chips must receive the taps that land
// on them. They deliberately drive `tester.tapAt(Offset)` / raw hit tests
// rather than `find.byType(...)` — a finder-based tap would pass even if
// the widget tree and the hit region disagreed, which is the whole failure
// mode being guarded.
//
// Pumping a whole screen is against the house grain (see the frontend
// skill, §7) and is done here on purpose: the defect is a cross-widget
// geometry property that cannot exist in an isolated card.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/dashboard_screen.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/collapsing_app_bar.dart';
import 'package:patrimonio/widgets/currency_toggle_button.dart';

/// Endpoints whose handlers cast the body to a Map; everything else in the
/// dashboard's load fan-out reads a list. Shapes only need to be
/// well-typed — the assertions are about geometry, not numbers.
const _mapEndpoints = <String>[
  '/dashboard/since-last-login',
  '/dashboard/spending-insights',
  '/dashboard/emergency-fund',
  '/dashboard/realized-gains',
  '/dashboard/fx-transfers/costs',
  '/dashboard/spending-by-category',
  '/dashboard/portfolio-twr',
  '/dashboard/benchmark',
  '/dashboard/benchmark-comparison',
  '/dashboard/holdings/dividends',
  '/recurring/upcoming',
  '/recurring/calendar',
  '/loans/summary',
  '/dashboard/net-worth-attribution',
];

http.Client _stubBackend() => MockClient((request) async {
  final p = request.url.path;
  Object body;
  if (p.endsWith('/overview')) {
    body = {
      'net_worth': 1000.0,
      'total_assets': 1200.0,
      'total_liabilities': 200.0,
      'accounts': [
        {
          'id': 1,
          'name': 'Checking',
          'institution_name': 'Bank',
          'type': 'depository',
          'subtype': 'checking',
          'balance': 1000.0,
          'currency': 'USD',
        },
      ],
    };
  } else if (p.contains('/fx/latest')) {
    body = {
      'rate': 17.51,
      'base': 'USD',
      'target': 'MXN',
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
    };
  } else if (p.contains('setup')) {
    body = {'ready_for_plaid_linking': true, 'checks': <dynamic>[]};
  } else if (p.contains('notifications')) {
    body = {'notifications': <dynamic>[], 'unread_count': 0};
  } else if (p.endsWith('/dashboard/holdings')) {
    body = {'holdings': <dynamic>[], 'total_value': 0.0};
  } else if (_mapEndpoints.any(p.endsWith)) {
    body = <String, dynamic>{};
  } else {
    body = <dynamic>[];
  }
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
});

/// Mounts the real dashboard at [size] with a stubbed backend and pumps
/// until the initial load has landed.
///
/// Doubles as the regression test for the initial load itself: the load is
/// kicked off from a post-frame callback because `_loadAllData` reads
/// `Theme.of(context)`, which is illegal until `initState` has returned.
/// Every assertion below needs a loaded dashboard, so if that call ever
/// moves back into `initState` these tests go red on the skeleton.
Future<void> _pumpDashboard(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DashboardScreen(),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// The render box of the tappable reporting-currency control for [size]:
/// the combined "USD · rate" chip on compact widths, the standalone
/// [CurrencyToggleButton] on wide ones.
RenderBox _currencyControl(WidgetTester tester, {required bool compact}) {
  final finder = compact
      ? find
            .ancestor(
              of: find.textContaining('17.51').first,
              matching: find.byType(InkWell),
            )
            .first
      : find
            .descendant(
              of: find.byType(CurrencyToggleButton),
              matching: find.byType(InkWell),
            )
            .first;
  return tester.renderObject<RenderBox>(finder);
}

Rect _globalRect(RenderBox box) => box.localToGlobal(Offset.zero) & box.size;

/// Every point on a 4px lattice over [region] that hit-tests into [target].
List<Offset> _pointsHitting(
  WidgetTester tester,
  Rect region,
  RenderObject target,
) {
  final hits = <Offset>[];
  for (var y = region.top; y <= region.bottom; y += 4) {
    for (var x = region.left; x <= region.right; x += 4) {
      final result = HitTestResult();
      // ignore: invalid_use_of_protected_member
      WidgetsBinding.instance.hitTestInView(
        result,
        Offset(x, y),
        tester.view.viewId,
      );
      if (result.path.any((e) => identical(e.target, target))) {
        hits.add(Offset(x, y));
      }
    }
  }
  return hits;
}

String _currencyChipLabel(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .firstWhere((s) => s.contains('17.51'), orElse: () => '<no currency chip>');

void main() {
  const phone = Size(390, 844);
  const desktop = Size(1280, 900);

  // The band the rig accused: from just under the app bar down past the
  // period chips, across the right-hand side of the screen.
  const phantomPhone = Rect.fromLTRB(240, 57, 389, 160);
  const phantomDesktop = Rect.fromLTRB(1100, 57, 1279, 140);

  setUp(() {
    ApiService.clearDashboardCache();
    ApiService.debugHttpClientOverride = _stubBackend();
  });
  tearDown(() => ApiService.debugHttpClientOverride = null);

  group('reporting-currency control hit region', () {
    testWidgets('never extends below the app bar, on any tab (phone)', (
      tester,
    ) async {
      await _pumpDashboard(tester, phone);
      for (final tab in ['Home', 'Activity', 'Cash']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        final control = _currencyControl(tester, compact: true);
        expect(
          _globalRect(control).bottom,
          lessThanOrEqualTo(kToolbarHeight),
          reason: '$tab: the currency chip must lay out inside the app bar',
        );
        expect(
          _pointsHitting(tester, phantomPhone, control),
          isEmpty,
          reason:
              '$tab: no point below the app bar may hit-test into the '
              'currency chip — a tap there would silently re-denominate '
              'every figure on screen',
        );
      }
    });

    testWidgets('stays inside its painted box once the app bar scrolls away', (
      tester,
    ) async {
      await _pumpDashboard(tester, phone);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      final control = _currencyControl(tester, compact: true);

      // Two drags: `barVisibleAfter` only retracts on a reverse scroll that
      // is already past kToolbarHeight, and the first drag's
      // UserScrollNotification fires while the offset is still 0.
      for (var i = 0; i < 2; i++) {
        await tester.dragFrom(const Offset(195, 400), const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(
        tester.getSize(find.byType(CollapsingAppBar)).height,
        lessThan(1.0),
        reason: 'premise: the app bar has actually scrolled away',
      );
      expect(
        _pointsHitting(tester, const Rect.fromLTRB(240, 0, 389, 160), control),
        isEmpty,
        reason:
            'a retracted app bar must not leave the currency chip '
            'hit-testable over the tab content',
      );
    });

    testWidgets('never extends below the app bar (wide)', (tester) async {
      await _pumpDashboard(tester, desktop);
      final control = _currencyControl(tester, compact: false);
      expect(_globalRect(control).bottom, lessThanOrEqualTo(kToolbarHeight));
      expect(
        _pointsHitting(tester, phantomDesktop, control),
        isEmpty,
        reason: 'wide layouts must not overhang the body either',
      );
    });
  });

  group('Cash flow period chips receive their own taps', () {
    testWidgets('tapping "This year" at its real coordinates changes the '
        'period and not the currency', (tester) async {
      await _pumpDashboard(tester, phone);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();

      final l = AppLocalizations.of(
        tester.element(find.byType(DashboardScreen)),
      );
      final chip = tester.getRect(find.text(l.cfPeriodYtdShort));
      // Guards the premise: the chip really does sit in the band the rig
      // accused, so this tap is the contested one.
      expect(chip.center.dy, greaterThan(kToolbarHeight));

      final before = _currencyChipLabel(tester);
      // Raw coordinate tap — the point of the test is that the hit region
      // and the widget tree must agree.
      await tester.tapAt(chip.center);
      await tester.pumpAndSettle();

      expect(
        find.textContaining(l.cfPeriodYtd),
        findsWidgets,
        reason:
            'the "This year" chip must select the year-to-date period; if a '
            'stray hit region swallowed the tap it would still read as the '
            'default month',
      );
      expect(
        _currencyChipLabel(tester),
        before,
        reason: 'tapping a period chip must never swap the reporting currency',
      );
    });

    testWidgets('no tap anywhere in the accused band re-denominates the app', (
      tester,
    ) async {
      // Mechanism-agnostic companion to the hit-region sweeps above: those
      // prove the app bar's control owns no geometry down here, this proves
      // nothing ELSE down here toggles the reporting currency either (a
      // phantom implemented by some other widget would slip past a sweep
      // that keys off one render object).
      await _pumpDashboard(tester, phone);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      final before = _currencyChipLabel(tester);
      expect(before, startsWith('USD'));

      for (final y in const [60.0, 94.0, 130.0, 155.0]) {
        for (final x in const [264.0, 300.0, 340.0, 380.0]) {
          await tester.tapAt(Offset(x, y));
          await tester.pumpAndSettle();
          expect(
            _currencyChipLabel(tester),
            startsWith('USD'),
            reason: 'a tap at ($x, $y) swapped the reporting currency',
          );
        }
      }
    });
  });
}
