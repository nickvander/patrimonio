import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/home_widget_snapshot.dart';

// The Android home-screen widget's payload. A RemoteViews tree can't be
// pumped, so this is the only part of the widget testable off an emulator —
// which is exactly why every decision that CAN live in Dart does.
//
// The rule these pin: the widget never formats money itself. It renders
// strings built here off the same reporting currency and rate as the hero
// number, so the tile can't disagree with the app it opens into.

void main() {
  group('buildHomeWidgetSnapshot', () {
    HomeWidgetSnapshot build({
      double? netWorthUsd = 1618279.43,
      double conversionFactor = 1.0,
      String reportingCurrency = 'USD',
      double? usdMxnRate = 17.153821,
      DateTime? syncedAt,
      bool showNetWorth = true,
      bool showFx = true,
      bool showSync = true,
    }) => buildHomeWidgetSnapshot(
      netWorthUsd: netWorthUsd,
      conversionFactor: conversionFactor,
      reportingCurrency: reportingCurrency,
      usdMxnRate: usdMxnRate,
      syncedAt: syncedAt,
      now: DateTime.utc(2026, 8, 9, 12),
      showNetWorth: showNetWorth,
      showFx: showFx,
      showSync: showSync,
    );

    test('net worth is whole-dollar — cents would ellipse on a 2x1 tile', () {
      expect(build().netWorth, r'$1,618,279');
    });

    test('reports in MXN when that is the reporting currency', () {
      // Same conversionFactor contract as every card: base USD scaled up.
      final s = build(
        netWorthUsd: 1000.0,
        conversionFactor: 17.153821,
        reportingCurrency: 'MXN',
      );
      // The ISO prefix, not a bare "$" — that glyph is also the peso sign.
      expect(s.netWorth, contains('MXN'));
      expect(s.netWorth, contains('17,154'));
    });

    test('the rate is a plain two-decimal number, never money', () {
      expect(build().fxRate, '17.15');
    });

    test('an absent or unusable rate renders nothing, not a zero', () {
      // A widget showing "USD/MXN 0.00" is a lie the user might act on.
      expect(build(usdMxnRate: null).fxRate, isNull);
      expect(build(usdMxnRate: 0).fxRate, isNull);
      expect(build(usdMxnRate: -1).fxRate, isNull);
    });

    test('a missing net worth renders nothing rather than \$0', () {
      expect(build(netWorthUsd: null).netWorth, isNull);
    });

    test('toWidgetData carries every key the Kotlin provider reads', () {
      final data = build(syncedAt: DateTime.utc(2026, 8, 9, 10)).toWidgetData();
      // This map IS the contract with PatrimonioWidgetProvider.kt — a renamed
      // key here silently blanks a row on the home screen.
      expect(data.keys.toSet(), {
        'net_worth',
        'fx_rate',
        'synced_at',
        'show_net_worth',
        'show_fx',
        'show_sync',
      });
      expect(data['show_net_worth'], 'true');
      expect(data['synced_at'], '2h ago');
    });

    test('nulls cross the bridge as empty strings, not the text "null"', () {
      final data = build(netWorthUsd: null, usdMxnRate: null).toWidgetData();
      expect(data['net_worth'], '');
      expect(data['fx_rate'], '');
      expect(data['synced_at'], '');
    });

    test('isEmpty only when every section is off', () {
      expect(build().isEmpty, isFalse);
      expect(build(showNetWorth: false, showFx: false).isEmpty, isFalse);
      expect(
        build(showNetWorth: false, showFx: false, showSync: false).isEmpty,
        isTrue,
      );
    });
  });

  group('formatWidgetAge', () {
    final now = DateTime.utc(2026, 8, 9, 12);

    test('coarsens through minutes, hours, days', () {
      expect(
        formatWidgetAge(now.subtract(const Duration(seconds: 20)), now),
        'just now',
      );
      expect(
        formatWidgetAge(now.subtract(const Duration(minutes: 5)), now),
        '5m ago',
      );
      expect(
        formatWidgetAge(now.subtract(const Duration(hours: 2)), now),
        '2h ago',
      );
      expect(
        formatWidgetAge(now.subtract(const Duration(days: 3)), now),
        '3d ago',
      );
    });

    test('boundaries land on the coarser unit', () {
      expect(
        formatWidgetAge(now.subtract(const Duration(minutes: 59)), now),
        '59m ago',
      );
      expect(
        formatWidgetAge(now.subtract(const Duration(minutes: 60)), now),
        '1h ago',
      );
      expect(
        formatWidgetAge(now.subtract(const Duration(hours: 23)), now),
        '23h ago',
      );
      expect(
        formatWidgetAge(now.subtract(const Duration(hours: 24)), now),
        '1d ago',
      );
    });

    // Clock skew after a timezone change would otherwise render "-3h ago".
    test('a future timestamp reads as now, never a negative age', () {
      expect(
        formatWidgetAge(now.add(const Duration(hours: 3)), now),
        'just now',
      );
    });

    test('labels are injectable so the tile follows the app locale', () {
      final es = HomeWidgetAgeLabels(
        justNow: 'ahora',
        minutes: (n) => 'hace $n min',
        hours: (n) => 'hace $n h',
        days: (n) => 'hace $n d',
      );
      expect(
        formatWidgetAge(
          now.subtract(const Duration(hours: 2)),
          now,
          labels: es,
        ),
        'hace 2 h',
      );
      expect(formatWidgetAge(now, now, labels: es), 'ahora');
    });
  });
}
