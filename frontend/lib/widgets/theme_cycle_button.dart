import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show themeModeNotifier;
import '../services/preferences.dart';

/// Single-tap theme picker. Tapping cycles system → light → dark →
/// system; long-press still surfaces the explicit picker for users who
/// know exactly which mode they want without cycling.
class ThemeCycleButton extends StatelessWidget {
  const ThemeCycleButton({super.key});

  static const _order = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];

  IconData _iconFor(ThemeMode m) => switch (m) {
    ThemeMode.system => Icons.brightness_auto,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };

  String _labelFor(AppLocalizations l, ThemeMode m) => switch (m) {
    ThemeMode.system => l.dashThemeSystem,
    ThemeMode.light => l.dashThemeLight,
    ThemeMode.dark => l.dashThemeDark,
  };

  void _persist(ThemeMode m) => Preferences.setThemeMode(switch (m) {
    ThemeMode.system => 'system',
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (ctx, mode, _) {
        return GestureDetector(
          onLongPress: () async {
            final picked = await showMenu<ThemeMode>(
              context: context,
              position: const RelativeRect.fromLTRB(1000, 56, 0, 0),
              items: [
                PopupMenuItem(
                  value: ThemeMode.system,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.brightness_auto),
                    title: Text(l.dashThemeSystemDefault),
                  ),
                ),
                PopupMenuItem(
                  value: ThemeMode.light,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.light_mode_outlined),
                    title: Text(l.dashThemeLightShort),
                  ),
                ),
                PopupMenuItem(
                  value: ThemeMode.dark,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.dark_mode_outlined),
                    title: Text(l.dashThemeDarkShort),
                  ),
                ),
              ],
            );
            if (picked != null) {
              themeModeNotifier.value = picked;
              _persist(picked);
            }
          },
          child: IconButton(
            tooltip: l.dashThemeTooltip(_labelFor(l, mode)),
            // AnimatedSwitcher fades between the per-mode icons so the
            // tap-cycle reads as a smooth icon swap rather than an
            // instant glyph flip.
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: anim, child: child),
              ),
              child: Icon(_iconFor(mode), key: ValueKey(mode)),
            ),
            onPressed: () {
              final next = _order[(_order.indexOf(mode) + 1) % _order.length];
              themeModeNotifier.value = next;
              _persist(next);
            },
          ),
        );
      },
    );
  }
}
