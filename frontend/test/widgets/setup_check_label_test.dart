// Regression test: the Settings "Launch setup" checklist used to render the
// backend's English `label` strings verbatim, so the card stayed in English
// under es-MX. Labels are now resolved from the stable `key` each check
// carries via setupCheckLabel(), with the server label only as a fallback
// for unknown keys. These tests pin the es rendering (and the en baseline)
// so a regression back to server-label rendering fails loudly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/setup_check_l10n.dart';

/// The stable keys `/api/setup/status` returns today, paired with the
/// English labels the backend still ships for backward compat (used here
/// as the fallback argument, exactly like the dashboard call site).
const _serverChecks = <String, String>{
  'plaid': 'Plaid account linking',
  'encryption': 'Credential encryption',
  'fx': 'Exchange rates',
  'coinbase': 'Coinbase OAuth',
  'plaid_webhook': 'Plaid webhook URL',
  'cors': 'CORS allow-list',
};

/// Minimal localized host that renders one Text per check, resolved the
/// same way buildSetupStatusCard does (key first, server label fallback).
Widget _host({required Locale locale}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            final l = AppLocalizations.of(context);
            return Column(
              children: [
                for (final entry in _serverChecks.entries)
                  Text(setupCheckLabel(l, entry.key, entry.value)),
              ],
            );
          },
        ),
      ),
    );

void main() {
  testWidgets('es: every launch-setup check label renders in Spanish',
      (tester) async {
    await tester.pumpWidget(_host(locale: const Locale('es')));
    await tester.pumpAndSettle();

    expect(find.text('Vinculación de cuentas con Plaid'), findsOneWidget);
    expect(find.text('Cifrado de credenciales'), findsOneWidget);
    expect(find.text('Tipos de cambio'), findsOneWidget);
    expect(find.text('OAuth de Coinbase'), findsOneWidget);
    expect(find.text('URL del webhook de Plaid'), findsOneWidget);
    expect(
        find.text('Lista de orígenes permitidos (CORS)'), findsOneWidget);

    // The bug being pinned: no row may fall through to the backend's
    // English label when the locale is es.
    for (final english in _serverChecks.values) {
      expect(find.text(english), findsNothing,
          reason: 'check rendered the server English label "$english" '
              'under es — key mapping regressed');
    }
  });

  testWidgets('en: labels match the backend strings 1:1', (tester) async {
    // Keeping en byte-identical to the server labels means older backends
    // and this frontend agree on wording in the default locale.
    await tester.pumpWidget(_host(locale: const Locale('en')));
    await tester.pumpAndSettle();

    for (final english in _serverChecks.values) {
      expect(find.text(english), findsOneWidget);
    }
  });

  testWidgets('unknown key falls back to the server-provided label',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Text(setupCheckLabel(
              AppLocalizations.of(context),
              'future_check',
              'Some future check')),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Some future check'), findsOneWidget);
  });
}
