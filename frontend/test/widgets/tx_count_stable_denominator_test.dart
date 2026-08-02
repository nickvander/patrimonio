import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

/// Regression tests for the stable "Showing X of N" denominator.
///
/// The fix: with the backend's X-Total-Count header plumbed into
/// [TransactionsTab.totalCount], the count line's denominator is the true
/// server total from the very first page and NEVER moves while the
/// whole-history filter cascade streams pages in — only the numerator
/// (matching rows) grows, under an explicit "Loading full history…" note.
/// Pre-fix the denominator was the loaded count, so it visibly counted up
/// 50 → 550 → 1050 → ... while the cascade ran, reading as a glitch.
/// Without the header (totalCount null) behavior must stay byte-identical
/// to the old loaded-count fallback.

/// Normalize non-breaking space codepoints so es-MX strings can be
/// asserted without pinning the exact whitespace codepoint.
String _normSpace(String s) => s.replaceAll(' ', ' ').replaceAll(' ', ' ');

List<Map<String, dynamic>> _rows(int n) {
  final today = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      {
        'id': 'tx-$i',
        'date': DateFormat(
          'yyyy-MM-dd',
        ).format(today.subtract(Duration(days: i))),
        'amount': 10.0 + i,
        'currency': 'USD',
        'description': 'MERCHANT $i',
        'user_description': 'Row $i',
        'category': 'FOOD_AND_DRINK',
        'account_name': 'Checking',
      },
  ];
}

Widget _localizedApp(Widget body, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(primary: false, child: body)),
);

/// Dashboard-style paginated parent that ALSO reports the header total the
/// way `_DashboardScreenState` does with the new backend: the total is
/// known from the first page and `hasMore` is exact (loaded < total).
/// [categorySeed] plants an active filter so the tab's whole-history
/// cascade kicks off on its own.
class _PagedHost extends StatefulWidget {
  static const int initialPage = 50;
  final List<Map<String, dynamic>> allRows;
  final String? categorySeed;
  const _PagedHost({required this.allRows, this.categorySeed});

  @override
  State<_PagedHost> createState() => _PagedHostState();
}

class _PagedHostState extends State<_PagedHost> {
  late List<dynamic> _loaded = widget.allRows
      .take(_PagedHost.initialPage)
      .toList();
  // X-Total-Count arrives with the very first page.
  late final int _total = widget.allRows.length;
  late bool _hasMore = _loaded.length < _total;
  String? _categorySeed;

  @override
  void initState() {
    super.initState();
    _categorySeed = widget.categorySeed;
  }

  Future<void> _loadMore({int? limit}) async {
    final page = limit ?? _PagedHost.initialPage;
    // A "network" latency of a few frames, so the test's 10ms sampling
    // pumps observe the count line BETWEEN page landings (a zero-delay
    // fetch lets the whole cascade finish inside one or two pumps and
    // hides the intermediate numerators this test is about).
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (!mounted) return;
    setState(() {
      final next = widget.allRows.skip(_loaded.length).take(page).toList();
      _loaded = [..._loaded, ...next];
      _hasMore = _loaded.length < _total;
    });
  }

  @override
  Widget build(BuildContext context) => TransactionsTab(
    transactions: _loaded,
    conversionFactor: 1.0,
    currencyFormat: NumberFormat.currency(symbol: r'$'),
    targetCurrency: 'USD',
    usdMxnRate: 0,
    onLoadMore: _loadMore,
    hasMore: _hasMore,
    totalCount: _total,
    categorySeed: _categorySeed,
    onCategorySeedConsumed: () => setState(() => _categorySeed = null),
  );
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Rendered count line ("Showing X of N" / "Mostrando X de N"), or null
/// when it isn't on screen.
String? _countLine(WidgetTester tester, String prefix) {
  final texts = tester
      .widgetList<Text>(find.textContaining(prefix))
      .map((t) => _normSpace(t.data ?? ''))
      .where((s) => s.startsWith(prefix))
      .toList();
  return texts.isEmpty ? null : texts.single;
}

TransactionsTab _staticTab(List<dynamic> txs, {int? totalCount}) =>
    TransactionsTab(
      transactions: txs,
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(symbol: r'$'),
      targetCurrency: 'USD',
      usdMxnRate: 0,
      totalCount: totalCount,
    );

void main() {
  group('count line denominator — bilingual, immediate', () {
    testWidgets('en: totalCount renders as the denominator from the first '
        'frame ("Showing 27 of 2502")', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _localizedApp(_staticTab(_rows(27), totalCount: 2502)),
      );
      await tester.pump();
      expect(_countLine(tester, 'Showing '), 'Showing 27 of 2502');
    });

    testWidgets('es: "Mostrando 27 de 2502"', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _localizedApp(
          _staticTab(_rows(27), totalCount: 2502),
          locale: const Locale('es'),
        ),
      );
      await tester.pump();
      expect(_countLine(tester, 'Mostrando '), 'Mostrando 27 de 2502');
    });

    testWidgets('totalCount null falls back to the loaded count — '
        'byte-identical to the pre-header behavior', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_localizedApp(_staticTab(_rows(27))));
      await tester.pump();
      expect(_countLine(tester, 'Showing '), 'Showing 27 of 27');
    });
  });

  group('stable denominator while the cascade streams pages', () {
    // Fixed-duration pumps: between cascade iterations only the host's
    // fetch timer is pending, so pumpAndSettle would settle early.
    Future<void> pumpFrames(WidgetTester tester, int frames) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('en: denominator is byte-identical after every page '
        'landing; numerator grows; loading note shows then goes', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _localizedApp(
          // Category seed = an ACTIVE filter → the tab cascades the whole
          // history on its own through onLoadMore.
          _PagedHost(allRows: _rows(1100), categorySeed: 'Food & drink'),
        ),
      );
      await tester.pump(); // post-frame seed application
      await tester.pump();

      final numerators = <String>[];
      final denominators = <String>{};
      var sawLoadingNote = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        final line = _countLine(tester, 'Showing ');
        if (line != null) {
          final match = RegExp(r'^Showing (\d+) of (\d+)$').firstMatch(line);
          expect(match, isNotNull, reason: 'unparsable count line: $line');
          numerators.add(match!.group(1)!);
          denominators.add(match.group(2)!);
        }
        sawLoadingNote =
            sawLoadingNote ||
            find.text('Loading full history…').evaluate().isNotEmpty;
      }

      // The denominator NEVER moved — one distinct value, the server total.
      expect(denominators, {'1100'});
      // The numerator legitimately grew as matching pages landed.
      expect(numerators.toSet().length, greaterThan(1));
      expect(numerators.last, '1100');
      // The in-progress affordance was visible mid-cascade…
      expect(
        sawLoadingNote,
        isTrue,
        reason: 'the loading note must accompany the growing numerator',
      );
      // …and is gone once the cascade settles.
      await pumpFrames(tester, 4);
      expect(find.text('Loading full history…'), findsNothing);
    });

    testWidgets('es: same contract, localized note', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _localizedApp(
          _PagedHost(allRows: _rows(1100), categorySeed: 'Food & drink'),
          locale: const Locale('es'),
        ),
      );
      await tester.pump();
      await tester.pump();

      final denominators = <String>{};
      var sawLoadingNote = false;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        final line = _countLine(tester, 'Mostrando ');
        if (line != null) {
          denominators.add(line.split(' de ').last);
        }
        sawLoadingNote =
            sawLoadingNote ||
            find.text('Cargando el historial completo…').evaluate().isNotEmpty;
      }
      expect(denominators, {'1100'});
      expect(sawLoadingNote, isTrue);
      await pumpFrames(tester, 4);
      expect(find.text('Cargando el historial completo…'), findsNothing);
    });
  });
}
