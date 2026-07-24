import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/movers.dart';

Map<String, dynamic> _h(String symbol, {double? gl, double? day}) => {
      'symbol': symbol,
      'gain_loss_usd': gl,
      'day_change_usd': day,
    };

void main() {
  group('topDollarMovers', () {
    test('ranks gainers descending and losers most-negative first', () {
      final holdings = [
        _h('A', gl: 100),
        _h('B', gl: 900),
        _h('C', gl: -50),
        _h('D', gl: -700),
        _h('E', gl: 400),
      ];
      final r = topDollarMovers(holdings, field: 'gain_loss_usd');
      expect(r.gainers.map((h) => h['symbol']), ['B', 'E', 'A']);
      expect(r.losers.map((h) => h['symbol']), ['D', 'C']);
    });

    test('caps each side at count', () {
      final holdings = [
        for (var i = 1; i <= 5; i++) _h('G$i', gl: i * 10.0),
        for (var i = 1; i <= 5; i++) _h('L$i', gl: i * -10.0),
      ];
      final r = topDollarMovers(holdings, field: 'gain_loss_usd', count: 2);
      expect(r.gainers.map((h) => h['symbol']), ['G5', 'G4']);
      expect(r.losers.map((h) => h['symbol']), ['L5', 'L4']);
    });

    test('null field values are skipped, zeros land in neither list', () {
      final holdings = [
        _h('KNOWN', gl: 10),
        _h('NOBASIS', gl: null),
        _h('FLAT', gl: 0),
        'not-a-map',
      ];
      final r = topDollarMovers(holdings, field: 'gain_loss_usd');
      expect(r.gainers.map((h) => h['symbol']), ['KNOWN']);
      expect(r.losers, isEmpty);
    });

    test('day_change_usd ranks independently of all-time gain/loss', () {
      // JNJ is the big all-time winner but today's biggest dollar loser;
      // TSLA is underwater all-time but leads today. The Today section
      // must reflect day_change_usd, not echo the all-time ranking.
      final holdings = [
        _h('JNJ', gl: 5000, day: -731.53),
        _h('TSLA', gl: -2000, day: 250.0),
        _h('CASH', gl: 0, day: null),
      ];
      final today = topDollarMovers(holdings, field: 'day_change_usd');
      expect(today.gainers.map((h) => h['symbol']), ['TSLA']);
      expect(today.losers.map((h) => h['symbol']), ['JNJ']);

      final allTime = topDollarMovers(holdings, field: 'gain_loss_usd');
      expect(allTime.gainers.map((h) => h['symbol']), ['JNJ']);
      expect(allTime.losers.map((h) => h['symbol']), ['TSLA']);
    });
  });
}
