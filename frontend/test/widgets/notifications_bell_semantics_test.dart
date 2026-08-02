import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/notifications_panel.dart';

// A live Playwright walkthrough drove the notifications surfaces by pixel
// coordinates because they exposed no usable semantics: the bell button's
// accessible name was the raw badge digit ("2") absorbed from the visual
// badge, and the mobile sheet's rows never claimed to be buttons. These
// tests pin the fixed exposure:
//  - the bell is a labeled button whose name includes the unread count
//    (l10n, both locales), never the bare digit;
//  - each notification row is ONE tappable node labeled with what the
//    notification says (title + detail) — the desktop popup gets this from
//    PopupMenuItem, the narrow sheet from the explicit MergeSemantics +
//    Semantics(button) wrap.

Widget _host(Widget bell, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(appBar: AppBar(actions: [bell])),
);

AppNotification _notif(String id, {String? title, String? detail}) =>
    AppNotification(
      id: id,
      icon: Icons.info_outline,
      accent: const Color(0xFF808080),
      title: title ?? 'title $id',
      detail: detail ?? 'detail $id',
      onTap: () {},
    );

void main() {
  group('bell button semantic label', () {
    testWidgets('en: labeled button with the unread count — not the badge '
        'digit', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(NotificationsBell(notifications: [_notif('a'), _notif('b')])),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Notifications, 2 unread alerts'),
        ),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Notifications, 2 unread alerts',
        ),
      );
      // The absorbed badge digit must be gone as an accessible name.
      expect(find.bySemanticsLabel('2'), findsNothing);
      handle.dispose();
    });

    testWidgets('en: singular form for one unread alert', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(NotificationsBell(notifications: [_notif('a')])),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Notifications, 1 unread alert'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('en: zero unread falls back to the plain name', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const NotificationsBell(notifications: [])),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.bySemanticsLabel('Notifications')),
        isSemantics(isButton: true, label: 'Notifications'),
      );
      handle.dispose();
    });

    testWidgets('es: label localized with the unread count', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          NotificationsBell(notifications: [_notif('a'), _notif('b')]),
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Notificaciones, 2 alertas sin leer'),
        ),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Notificaciones, 2 alertas sin leer',
        ),
      );
      handle.dispose();
    });

    testWidgets('es: zero unread falls back to the plain name', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const NotificationsBell(notifications: []),
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.bySemanticsLabel('Notificaciones')),
        isSemantics(isButton: true, label: 'Notificaciones'),
      );
      handle.dispose();
    });
  });

  group('notification rows announce as labeled tappable buttons', () {
    testWidgets('desktop popup: one button node carrying title + detail', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          NotificationsBell(
            notifications: [
              _notif(
                'a',
                title: 'Chase needs reconnecting',
                detail: 'Tap to fix the connection.',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Default 800px test surface takes the desktop popup path.
      await tester.tap(find.byType(NotificationsBell));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Chase needs reconnecting')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Chase needs reconnecting\nTap to fix the connection.',
        ),
      );
      handle.dispose();
    });

    testWidgets('narrow sheet: one button node carrying title + detail', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          NotificationsBell(
            notifications: [
              _notif(
                'a',
                title: 'Chase needs reconnecting',
                detail: 'Tap to fix the connection.',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Below the 600px breakpoint the bell opens the bottom sheet.
      await tester.tap(find.byType(NotificationsBell));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Chase needs reconnecting')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Chase needs reconnecting\nTap to fix the connection.',
        ),
      );
      handle.dispose();
    });
  });
}
