import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/main.dart' show themeModeNotifier;
import 'package:patrimonio/widgets/settings_cards.dart'
    show
        SettingsAccountSecurityCard,
        SettingsHomeWidgetCard,
        SettingsPreferencesCard;

// The Settings tab's app-level settings cards (Preferences and
// Account & security) — the settings home that replaces the AppBar kebab.
// Cards are pumped in isolation (tests never pump the full dashboard).

Widget _host(
  Widget child, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
}) => MaterialApp(
  locale: locale,
  theme: theme,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

SettingsAccountSecurityCard _accountCard({
  VoidCallback? onSignOut,
  VoidCallback? onHiddenItemsClosed,
  Future<void> Function()? onChangeServer,
}) => SettingsAccountSecurityCard(
  onHiddenItemsClosed: onHiddenItemsClosed ?? () {},
  onSignOut: onSignOut ?? () {},
  onChangeServer: onChangeServer ?? () async {},
);

void main() {
  group('SettingsPreferencesCard', () {
    testWidgets('en: shows Language row with the active-locale autonym', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const SettingsPreferencesCard()));
      await tester.pumpAndSettle();

      expect(find.text('Preferences'), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
      // Subtitle is the autonym of the ACTIVE locale.
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      // Connected button group: all three segment labels visible at rest.
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
    });

    testWidgets('es: localized headers + Spanish autonym subtitle', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const SettingsPreferencesCard(), locale: const Locale('es')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Preferencias'), findsOneWidget);
      expect(find.text('Idioma'), findsOneWidget);
      expect(find.text('Español (México)'), findsOneWidget);
      expect(find.text('Tema'), findsOneWidget);
    });

    testWidgets('Language row opens a radio picker with BOTH autonyms; '
        'cancel keeps the locale', (tester) async {
      await tester.pumpWidget(_host(const SettingsPreferencesCard()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();

      // Both options always show their own name, never a translation.
      expect(find.byType(RadioListTile<String>), findsNWidgets(2));
      expect(find.text('Español (México)'), findsOneWidget);
      // 'English' appears twice: the row subtitle + the dialog option.
      expect(find.text('English'), findsNWidgets(2));

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(RadioListTile<String>), findsNothing);
      // Still English — cancel must not persist anything.
      expect(find.text('Language'), findsOneWidget);
    });

    testWidgets('a11y: language dialog options expose their labels and '
        'selected state (en active)', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const SettingsPreferencesCard()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();

      // RadioListTile already merges the autonym title with the radio's
      // checked state into one tappable node — pinned here so a refactor
      // away from RadioListTile can't silently regress the exposure the
      // Playwright walkthrough flagged. (`.last`: the card subtitle also
      // says 'English' in en.)
      expect(
        tester.getSemantics(find.text('English').last),
        isSemantics(
          label: 'English',
          hasTapAction: true,
          hasCheckedState: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('Español (México)').last),
        isSemantics(
          label: 'Español (México)',
          hasTapAction: true,
          hasCheckedState: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a11y: language dialog selected state follows the active '
        'locale (es active)', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const SettingsPreferencesCard(), locale: const Locale('es')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Idioma'));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Español (México)').last),
        isSemantics(
          label: 'Español (México)',
          hasCheckedState: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('English').last),
        isSemantics(
          label: 'English',
          hasCheckedState: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('theme selector tracks themeModeNotifier (e.g. the wide '
        'AppBar cycle button)', (tester) async {
      final original = themeModeNotifier.value;
      addTearDown(() => themeModeNotifier.value = original);

      themeModeNotifier.value = ThemeMode.light;
      await tester.pumpWidget(_host(const SettingsPreferencesCard()));
      await tester.pumpAndSettle();

      // The selected segment of the connected group renders its label at
      // w700; unselected segments at w600.
      FontWeight weightOf(String label) =>
          tester.widget<Text>(find.text(label)).style!.fontWeight!;
      expect(weightOf('Light'), FontWeight.w700);
      expect(weightOf('Dark'), FontWeight.w600);

      // External change (what the AppBar theme-cycle button does) must be
      // reflected without rebuilding the card from outside.
      themeModeNotifier.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(weightOf('Dark'), FontWeight.w700);
      expect(weightOf('Light'), FontWeight.w600);
    });

    testWidgets('renders without overflow on a narrow phone in es (long '
        'segment labels) and in dark theme', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          const SettingsPreferencesCard(),
          locale: const Locale('es'),
          theme: ThemeData(brightness: Brightness.dark),
        ),
      );
      await tester.pumpAndSettle();
      // Narrow layout stacks the picker under the label; an overflow would
      // fail the test via FlutterError.
      expect(find.text('Sistema'), findsOneWidget);
      expect(find.text('Oscuro'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('SettingsAccountSecurityCard', () {
    testWidgets('en: shows Security, Hidden items, Server (non-web test VM) '
        'and Sign out rows', (tester) async {
      await tester.pumpWidget(_host(_accountCard()));
      await tester.pumpAndSettle();

      expect(find.text('Account & security'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Hidden items'), findsOneWidget);
      // kIsWeb is false on the test VM, so the native-only Server row shows.
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('sign-out row shows the confirm dialog instead of signing '
        'out directly; cancel does nothing', (tester) async {
      var signedOut = false;
      await tester.pumpWidget(
        _host(_accountCard(onSignOut: () => signedOut = true)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      // The tap alone must NOT sign out — the confirmation comes first,
      // reusing the Security screen's bilingual strings.
      expect(signedOut, isFalse);
      expect(find.text('Sign out of this device?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(signedOut, isFalse);
      expect(find.text('Sign out of this device?'), findsNothing);
    });

    testWidgets('confirming the dialog fires onSignOut', (tester) async {
      var signedOut = false;
      await tester.pumpWidget(
        _host(_accountCard(onSignOut: () => signedOut = true)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      // The confirm action is the dialog's FilledButton (the row itself is a
      // ListTile, so the finder can't collide with it).
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(signedOut, isTrue);
    });

    testWidgets('es: sign-out confirmation uses the Spanish strings', (
      tester,
    ) async {
      var signedOut = false;
      await tester.pumpWidget(
        _host(
          _accountCard(onSignOut: () => signedOut = true),
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cuenta y seguridad'), findsOneWidget);
      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();

      expect(signedOut, isFalse);
      expect(find.text('¿Cerrar sesión en este dispositivo?'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(signedOut, isFalse);
    });

    testWidgets('server row asks for confirmation before onChangeServer', (
      tester,
    ) async {
      var changed = false;
      await tester.pumpWidget(
        _host(_accountCard(onChangeServer: () async => changed = true)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Server'));
      await tester.pumpAndSettle();
      expect(changed, isFalse);
      expect(find.text('Change server?'), findsOneWidget);
      expect(
        find.text('Changing the server will sign you out.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(changed, isFalse);

      await tester.tap(find.text('Server'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(changed, isTrue);
    });

    testWidgets('renders on a wide (>=720) window and in dark theme without '
        'overflow', (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          const Column(
            children: [SettingsPreferencesCard(), SizedBox(height: 24)],
          ),
          theme: ThemeData(brightness: Brightness.dark),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _host(_accountCard(), theme: ThemeData(brightness: Brightness.dark)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Sign out'), findsOneWidget);
    });
  });

  // The Android home-screen widget's config card. The widget itself is a
  // RemoteViews tree that cannot be pumped, so this — plus
  // home_widget_snapshot_test — is the whole off-emulator surface.
  group('SettingsHomeWidgetCard', () {
    testWidgets('all three sections default ON', (tester) async {
      await tester.pumpWidget(_host(SettingsHomeWidgetCard(onChanged: () {})));
      await tester.pumpAndSettle();

      // A freshly placed widget should be useful immediately; the user
      // subtracts rather than hunting for switches to make it show anything.
      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switches, hasLength(3));
      expect(switches.every((s) => s.value), isTrue);
      expect(find.text('Net worth'), findsOneWidget);
      expect(find.text('USD/MXN rate'), findsOneWidget);
      expect(find.text('Sync button'), findsOneWidget);
    });

    testWidgets('a toggle re-pushes immediately, not on the next load', (
      tester,
    ) async {
      var pushes = 0;
      await tester.pumpWidget(
        _host(SettingsHomeWidgetCard(onChanged: () => pushes++)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('USD/MXN rate'));
      await tester.pumpAndSettle();

      // A switch whose effect shows up minutes later reads as broken.
      expect(pushes, 1);
      expect(
        tester
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .elementAt(1)
            .value,
        isFalse,
      );
    });

    testWidgets('says the sync button opens the app rather than syncing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(SettingsHomeWidgetCard(onChanged: () {})));
      await tester.pumpAndSettle();

      // The widget does no networking; promising a silent background sync
      // would be the one thing this design cannot deliver.
      expect(
        find.text('Opens the app, which syncs and refreshes the widget'),
        findsOneWidget,
      );
    });

    testWidgets('warns when everything is switched off', (tester) async {
      await tester.pumpWidget(_host(SettingsHomeWidgetCard(onChanged: () {})));
      await tester.pumpAndSettle();

      expect(find.textContaining('just opens the app'), findsNothing);
      for (final label in ['Net worth', 'USD/MXN rate', 'Sync button']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      // The all-off tile is legal but must not look like a rendering bug.
      expect(find.textContaining('just opens the app'), findsOneWidget);
    });

    testWidgets('renders in es-MX', (tester) async {
      await tester.pumpWidget(
        _host(
          SettingsHomeWidgetCard(onChanged: () {}),
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Widget de pantalla de inicio'), findsOneWidget);
      expect(find.text('Patrimonio neto'), findsOneWidget);
      expect(find.text('Tipo de cambio USD/MXN'), findsOneWidget);
    });
  });
}
