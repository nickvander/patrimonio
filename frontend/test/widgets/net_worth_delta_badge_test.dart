import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/net_worth_delta.dart';
import 'package:patrimonio/widgets/net_worth_delta_badge.dart';

// The dashboard hero's net-worth change badge. Pinned here: the window label
// names the anchor the delta was ACTUALLY computed against — the badge used to
// hardcode "vs 30d ago" even when the comparison anchor was only days old
// (16 days of history on the dev account), contradicting the chart's honest
// "vs 7d ago" chip right below it. Both locales, both windows.

/// es NBSP-style codepoints must count as plain spaces so assertions prove
/// content without pinning the exact whitespace codepoint.
String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

/// Text finder that compares whitespace-normalized content.
Finder _findText(String expected) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      w.data != null &&
      _normSpace(w.data!) == _normSpace(expected),
);

Widget _host(Widget child, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

NetWorthDeltaBadge _badge(NetWorthDelta delta) => NetWorthDeltaBadge(
  delta: delta,
  currencyFormat: NumberFormat.currency(
    locale: 'en_US',
    name: 'USD',
    symbol: r'$',
  ),
  conversionFactor: 1.0,
);

void main() {
  group('NetWorthDeltaBadge — honest anchor label', () {
    test(
      'badge label reuses pfDeltaVsAgo — same copy as the chart chip',
      () async {
        final en = await AppLocalizations.delegate.load(const Locale('en'));
        expect(en.pfDeltaVsAgo('7d'), 'vs 7d ago');
        expect(en.pfDeltaVsAgo('30d'), 'vs 30d ago');
      },
    );

    testWidgets('7d fallback anchor is labeled "vs 7d ago" (en)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _badge(
            const NetWorthDelta(amount: 70, percentage: 6.4, windowLabel: '7d'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_findText('vs 7d ago'), findsOneWidget);
      expect(_findText(r'+$70.00 · +6.4%'), findsOneWidget);
    });

    testWidgets('30d anchor is labeled "vs 30d ago" (en)', (tester) async {
      await tester.pumpWidget(
        _host(
          _badge(
            const NetWorthDelta(
              amount: -120,
              percentage: -1.5,
              windowLabel: '30d',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_findText('vs 30d ago'), findsOneWidget);
      // Down deltas render the true minus sign on both figures.
      expect(_findText(r'−$120.00 · −1.5%'), findsOneWidget);
    });

    testWidgets('7d fallback anchor is labeled "vs. hace 7d" (es)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _badge(
            const NetWorthDelta(amount: 70, percentage: 6.4, windowLabel: '7d'),
          ),
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_findText('vs. hace 7d'), findsOneWidget);
      // es-MX percent conventions match en (CLDR es_MX: period decimal,
      // no space before %) — see utils/percent_format.dart.
      expect(_findText(r'+$70.00 · +6.4%'), findsOneWidget);
    });

    testWidgets('unreliable baseline (null %) shows the dollar delta alone', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _badge(
            const NetWorthDelta(
              amount: 500,
              percentage: null,
              windowLabel: '30d',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_findText(r'+$500.00'), findsOneWidget);
      expect(_findText('vs 30d ago'), findsOneWidget);
    });
  });
}
