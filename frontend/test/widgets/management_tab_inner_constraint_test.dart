// The data-management tab's phone branch must follow the width the TAB
// CONTENT was given, not the window (skill §4/§5).
//
// `buildTabContainer` pads the tab by 16 or 24 on every side and clamps its
// content to 1600px, so the content is always narrower than the window — by
// 48px once the window itself is ≥720. Deriving `isPhone` from
// `MediaQuery.sizeOf(context).width` therefore mis-branched the whole
// 720–768px window band: the tab content there is 672–720px (a touch-shaped
// column) while the window said "desktop", so the secondary controls (sync
// status, FX rate, modules) rendered inline instead of behind the
// "Connections & sync" disclosure, and the tab's cards took 24px of padding.
//
// Pumping a whole screen is against the house grain (frontend skill §7) and
// is done here on purpose: this branch is a property of the tab container's
// own geometry, which cannot exist in an isolated card.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/dashboard_screen.dart';
import 'package:patrimonio/services/api_service.dart';

/// Endpoints whose handlers cast the body to a Map; everything else in the
/// dashboard's load fan-out reads a list. Shapes only need to be well-typed —
/// these assertions are about layout, not numbers. (Mirrors the list in
/// `app_bar_hit_region_test.dart`, the other whole-screen test.)
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

/// Mounts the real dashboard at [size] and lets its initial load land. The
/// load is kicked off from a post-frame callback (it reads `Theme.of`), so
/// several pumps are needed before anything but the skeleton exists.
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

/// Navigates to the data-management ("Settings") destination and settles.
Future<void> _openManagementTab(WidgetTester tester) async {
  await tester.tap(find.text('Settings').last);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The tap-to-expand "Connections & sync" header — rendered only on the
/// touch-width branch, where the secondary controls hide behind it.
final _connectionsDisclosure = find.text('Connections & sync');

void main() {
  setUp(() {
    ApiService.clearDashboardCache();
    ApiService.debugHttpClientOverride = _stubBackend();
  });
  tearDown(() => ApiService.debugHttpClientOverride = null);

  testWidgets('a 740px window is a TOUCH-width management tab', (tester) async {
    // 740px window → the tab pads by 24 a side → 692px of content, below the
    // ~720 breakpoint. The MediaQuery version read 740 and called this
    // desktop, so the secondary controls sat inline in a 692px column.
    await _pumpDashboard(tester, const Size(740, 1400));
    await _openManagementTab(tester);

    expect(
      _connectionsDisclosure,
      findsOneWidget,
      reason: '692px of tab content is touch-shaped',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 1280px window keeps the management tab inline', (
    tester,
  ) async {
    await _pumpDashboard(tester, const Size(1280, 1400));
    await _openManagementTab(tester);

    expect(
      _connectionsDisclosure,
      findsNothing,
      reason: '1232px of tab content renders the controls inline',
    );
    expect(tester.takeException(), isNull);
  });
}
