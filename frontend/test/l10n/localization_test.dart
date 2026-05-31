import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// Verifies the l10n wiring end-to-end: the same AppLocalizations getters
// resolve to English vs hand-tuned es-MX strings purely from the active
// Locale. Pumps a minimal MaterialApp (no app screens) so this stays clear
// of the package:web widget-test hazard noted in MEMORY.
void main() {
  Future<void> pumpWithLocale(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final l = AppLocalizations.of(context);
            return Text('${l.navOverview}|${l.navLending}|${l.navMoreGroup}');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('English locale renders English nav labels', (tester) async {
    await pumpWithLocale(tester, const Locale('en'));
    expect(find.text('Overview|Lending|MORE'), findsOneWidget);
  });

  testWidgets('Spanish (es-MX) locale renders es-MX nav labels',
      (tester) async {
    await pumpWithLocale(tester, const Locale('es'));
    expect(find.text('Resumen|Préstamos|MÁS'), findsOneWidget);
  });

  Future<String> readKeys(WidgetTester tester, Locale locale,
      String Function(AppLocalizations l) pick) async {
    late String out;
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        out = pick(AppLocalizations.of(context));
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    return out;
  }

  testWidgets('tranche-2 strings localize (login / stats / lending)',
      (tester) async {
    String triple(AppLocalizations l) =>
        '${l.authSignIn}|${l.statNetWorth}|${l.lendingTitle}';
    expect(await readKeys(tester, const Locale('en'), triple),
        'Sign in|Net worth|Money I\'ve lent');
    expect(await readKeys(tester, const Locale('es'), triple),
        'Iniciar sesión|Patrimonio neto|Dinero que presté');
  });

  testWidgets('currency tooltip interpolates the code per locale',
      (tester) async {
    expect(
        await readKeys(
            tester, const Locale('es'), (l) => l.currencyToggleTooltip('MXN')),
        'Mostrando en MXN · toca para cambiar');
  });

  testWidgets('tranche-3 strings localize (tx / security / cashflow / dash)',
      (tester) async {
    String quad(AppLocalizations l) =>
        '${l.txSetCategory}|${l.secTitle}|${l.cfMonthlyTitle}|${l.dashSignOut}';
    expect(await readKeys(tester, const Locale('en'), quad),
        'Set category|Security|Cash flow this month|Sign out');
    expect(await readKeys(tester, const Locale('es'), quad),
        'Asignar categoría|Seguridad|Flujo de efectivo de este mes|Cerrar sesión');
  });

  testWidgets('a tranche-3 plural resolves both cases in es', (tester) async {
    expect(
        await readKeys(
            tester, const Locale('es'), (l) => l.cfChargesCount(1)),
        '1 cargo');
    expect(
        await readKeys(
            tester, const Locale('es'), (l) => l.cfChargesCount(5)),
        '5 cargos');
  });

  testWidgets('tranche-4 strings localize (proj / fx / portfolio / tax)',
      (tester) async {
    String quad(AppLocalizations l) =>
        '${l.projTitle}|${l.lwFxExchangeRate}|${l.pfInvestmentPortfolio}|${l.taxTitle}';
    expect(await readKeys(tester, const Locale('en'), quad),
        'Wealth projection|Exchange rate|Investment portfolio|Tax planning');
    expect(await readKeys(tester, const Locale('es'), quad),
        'Proyección de patrimonio|Tipo de cambio|Portafolio de inversión|Planeación fiscal');
  });

  test('both locales are supported', () {
    final codes =
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
    expect(codes.containsAll({'en', 'es'}), isTrue);
  });
}
