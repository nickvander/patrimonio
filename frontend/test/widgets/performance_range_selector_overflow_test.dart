import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/components/date_range_selector.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/performance_card.dart';

// Regression: the performance card's range row (benchmark chip + `Spacer` +
// the 1M/YTD/1Y/5Y/ALL selector) overflowed on a phone. Content-sized, the
// chip runs to ~150px and the selector to ~315px, which is ~465px of demand
// against ~350px of inner card on a 390pt phone — a 35px overflow there and
// ~65px at 420 (where the selector's horizontal padding steps 10 → 16). The
// owner's screenshots show this row, so it was plausibly clipped on a real
// device.
//
// The fix stacks them below a 520px INNER card width (the house Row→Column
// breakpoint, read off the card's own LayoutBuilder — never MediaQuery), with
// the selector full-bleed underneath via `DateRangeSelector.fill`. Pinned
// here: no overflow across the phone/tablet/desktop width sweep, and all five
// range options still on screen and actually tappable at the narrowest width.

/// The five range labels in template order, paired with the enum a tap on
/// each must select.
const _rangesEn = <(String, DateRange)>[
  ('1M', DateRange.oneMonth),
  ('YTD', DateRange.yearToDate),
  ('1Y', DateRange.oneYear),
  ('5Y', DateRange.fiveYears),
  ('ALL', DateRange.all),
];

/// es-MX labels — "Todo" is the widest of any range label in either locale,
/// so the es sweep is the worst case for the row branch.
const _rangesEs = <(String, DateRange)>[
  ('1M', DateRange.oneMonth),
  ('YTD', DateRange.yearToDate),
  ('1A', DateRange.oneYear),
  ('5A', DateRange.fiveYears),
  ('Todo', DateRange.all),
];

Widget _host(Widget child, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// Dollar-line branch: three history points is enough to render the value
/// section (and therefore the range row) with no TWR and no comparison.
PerformanceCard _card() => PerformanceCard(
  apiService: ApiService(),
  conversionFactor: 1.0,
  currencyFormat: NumberFormat.currency(symbol: r'$'),
  historyFetchOverride: () async => <dynamic>[
    {'date': '2026-01-01', 'value_usd': 100000.0},
    {'date': '2026-02-01', 'value_usd': 110000.0},
    {'date': '2026-03-01', 'value_usd': 120000.0},
  ],
  comparisonFetchOverride: () async => null,
  twrFetchOverride: () async => null,
);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Records every framework error raised while the body runs (forwarding to
/// the binding so a real failure still surfaces normally), then fails on any
/// overflow. `takeException()` alone only surfaces the FIRST error; the log
/// catches a second overflow hiding behind the first.
Future<void> _expectNoOverflow(
  WidgetTester tester,
  String context,
  Future<void> Function() body,
) async {
  final logged = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    logged.add(details.exceptionAsString());
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  final overflows = logged
      .where((e) => e.contains('overflowed'))
      .toList(growable: false);
  expect(
    overflows,
    isEmpty,
    reason: 'RenderFlex overflow at $context: ${overflows.join(' | ')}',
  );
  expect(tester.takeException(), isNull, reason: 'exception at $context');
}

void main() {
  group('PerformanceCard — range row fits at phone widths', () {
    // 320 = the narrowest phone we support; 390/412/430 = real handsets;
    // 420 is the width the original report measured; 519/520 straddle the
    // stack breakpoint; the rest cover tablet and desktop.
    const widths = <double>[
      320,
      360,
      390,
      412,
      430,
      480,
      519,
      520,
      560,
      900,
      1440,
    ];

    for (final locale in <Locale?>[null, const Locale('es')]) {
      final name = locale?.languageCode ?? 'en';
      final ranges = locale == null ? _rangesEn : _rangesEs;

      for (final w in widths) {
        testWidgets('no overflow at ${w.toInt()}px ($name)', (tester) async {
          _useSurface(tester, Size(w, 900));
          await _expectNoOverflow(tester, '${w}px/$name', () async {
            await tester.pumpWidget(_host(_card(), locale: locale));
            await tester.pumpAndSettle();
          });

          // Every range option is rendered and lies fully inside the surface
          // — an overflowing Row still paints its children, just past the
          // edge, so "no exception" alone would not prove reachability.
          for (final (label, _) in ranges) {
            final f = find.text(label);
            expect(f, findsOneWidget, reason: '$label missing at ${w}px');
            final rect = tester.getRect(f);
            expect(
              rect.left,
              greaterThanOrEqualTo(0.0),
              reason: '$label clipped left at ${w}px',
            );
            expect(
              rect.right,
              lessThanOrEqualTo(w),
              reason: '$label clipped right at ${w}px',
            );
          }
        });
      }

      testWidgets('all five options are tappable at 390px ($name)', (
        tester,
      ) async {
        _useSurface(tester, const Size(390, 900));
        await tester.pumpWidget(_host(_card(), locale: locale));
        await tester.pumpAndSettle();

        DateRangeSelector selector() =>
            tester.widget<DateRangeSelector>(find.byType(DateRangeSelector));

        // Below the breakpoint the selector fills its line — the mode whose
        // equal-flex segments are what keep five options reachable here.
        expect(selector().fill, isTrue);

        for (final (label, range) in ranges) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(
            selector().selectedRange,
            range,
            reason: 'tapping $label did not select it at 390px',
          );
          // A 44dp-minimum hit height is the component's touch contract.
          expect(
            tester
                .getSize(
                  find
                      .ancestor(
                        of: find.text(label),
                        matching: find.byType(InkWell),
                      )
                      .first,
                )
                .height,
            greaterThanOrEqualTo(44.0),
          );
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('stacks below the breakpoint, shares a line above it', (
      tester,
    ) async {
      // The card sits inside a Card (4px default margin per side) with 16px
      // of padding on phones, so a 390pt surface is ~350pt of inner width —
      // comfortably below the 520 breakpoint.
      _useSurface(tester, const Size(390, 900));
      await tester.pumpWidget(_host(_card()));
      await tester.pumpAndSettle();
      final phoneSelector = tester.widget<DateRangeSelector>(
        find.byType(DateRangeSelector),
      );
      expect(phoneSelector.fill, isTrue);
      // Stacked: the chip sits ABOVE the segments, not beside them.
      expect(
        tester.getRect(find.byType(DateRangeSelector)).top,
        greaterThan(tester.getRect(find.text('S&P 500')).bottom),
      );

      // Desktop: back to one line, chip left of the segments.
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(_card()));
      await tester.pumpAndSettle();
      final wideSelector = tester.widget<DateRangeSelector>(
        find.byType(DateRangeSelector),
      );
      expect(wideSelector.fill, isFalse);
      final chip = tester.getRect(find.text('S&P 500'));
      final segments = tester.getRect(find.byType(DateRangeSelector));
      expect(segments.left, greaterThan(chip.right));
      expect(segments.center.dy, closeTo(chip.center.dy, 4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the widest benchmark label ellipsizes rather than pushing '
        'the segments off the row', (tester) async {
      // "Mundo (ACWI)" is the longest chip label in either locale. Just above
      // the breakpoint it is the case that used to re-open the overflow, so
      // the chip is Flexible: it can only shrink.
      _useSurface(tester, const Size(560, 900));
      await _expectNoOverflow(tester, '560px/es + ACWI', () async {
        await tester.pumpWidget(_host(_card(), locale: const Locale('es')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('S&P 500'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mundo (ACWI)').last);
        await tester.pumpAndSettle();
      });
      expect(find.text('Mundo (ACWI)'), findsOneWidget);
      for (final (label, _) in _rangesEs) {
        expect(find.text(label), findsOneWidget);
        expect(
          tester.getRect(find.text(label)).right,
          lessThanOrEqualTo(560.0),
        );
      }
    });
  });
}
