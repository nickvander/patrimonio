import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show themeModeNotifier;
import '../screens/hidden_items_screen.dart';
import '../screens/security_screen.dart';
import '../services/backend_config.dart';
import '../services/preferences.dart';
import '../utils/app_locale.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

/// Shows the shared sign-out confirmation dialog — the same bilingual strings
/// as the Security screen's "Sign out of this device" — and resolves to true
/// only if the user confirmed. Used by the Settings tab's Account & security
/// card and by the dashboard's own confirmed sign-out; public so widget tests
/// can exercise the flow.
Future<bool> confirmSignOutDialog(BuildContext context) async {
  final l = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l.secSignOutThisDeviceTitle),
      content: Text(l.secSignOutThisDeviceBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.secSignOut),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Preferences card on the Settings tab: language (explicit radio picker) and
/// theme (three-way segmented control). Reads/writes the app-global notifiers
/// (localeNotifier, themeModeNotifier) and persists via Preferences — the
/// exact persist+notify pattern the AppBar controls use, so both stay in
/// step. Public (unlike the dashboard's other cards) so widget tests can pump
/// it in isolation — tests never pump the full dashboard screen.
class SettingsPreferencesCard extends StatelessWidget {
  const SettingsPreferencesCard({super.key});

  void _pickLanguage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final current = Localizations.localeOf(context).languageCode;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.dashLanguageLabel),
        // Radio tiles carry their own horizontal padding; shrink the default
        // 24px content inset so they align under the title.
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (code) {
            if (code == null) return;
            // Same persist + live-notify pattern as the AppBar's language
            // toggle: Preferences stores it, localeNotifier re-points intl
            // and rebuilds MaterialApp.
            Preferences.setLocale(code);
            localeNotifier.value = Locale(code);
            Navigator.of(dialogContext).pop();
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Autonyms — deliberately NOT localized: each language names
              // itself so it stays findable from the "wrong" locale.
              RadioListTile<String>(value: 'en', title: Text('English')),
              RadioListTile<String>(
                value: 'es',
                title: Text('Español (México)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.actionCancel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, size: 18, color: context.tealAccent),
                const SizedBox(width: 8),
                Text(
                  l.dashPreferencesTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.translate),
              title: Text(l.dashLanguageLabel),
              subtitle: Text(
                // Autonym of the ACTIVE locale (deliberately not localized).
                Localizations.localeOf(context).languageCode == 'es'
                    ? 'Español (México)'
                    : 'English',
              ),
              onTap: () => _pickLanguage(context),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              // Width decisions off the card's INNER constraint (house
              // convention), not the screen.
              child: LayoutBuilder(
                builder: (ctx, c) {
                  final label = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.brightness_6_outlined),
                      const SizedBox(width: 16),
                      Text(
                        l.dashThemeMenu,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  );
                  // ValueListenableBuilder keeps the selection in step with
                  // theme changes made elsewhere (the wide AppBar's
                  // theme-cycle button writes the same notifier). Rendered as
                  // an M3 Expressive connected button group (2px gaps, no
                  // shared outline, selected segment morphs to a filled
                  // fully-rounded pill) — the classic SegmentedButton's
                  // outline+checkmark read as dated chrome, and equal-flex
                  // segments always fit the card, no scroll guard needed.
                  final picker = ValueListenableBuilder<ThemeMode>(
                    valueListenable: themeModeNotifier,
                    builder: (pickerCtx, mode, _) {
                      // The group's look lives in the shared
                      // ConnectedSegments widget (extracted from the
                      // inline builder that used to be here); only the
                      // persist logic stays local.
                      return ConnectedSegments<ThemeMode>(
                        segments: [
                          ConnectedSegment(
                            value: ThemeMode.system,
                            icon: Icons.brightness_auto,
                            label: l.dashThemeSystemShort,
                          ),
                          ConnectedSegment(
                            value: ThemeMode.light,
                            icon: Icons.light_mode_outlined,
                            label: l.dashThemeLightShort,
                          ),
                          ConnectedSegment(
                            value: ThemeMode.dark,
                            icon: Icons.dark_mode_outlined,
                            label: l.dashThemeDarkShort,
                          ),
                        ],
                        selected: mode,
                        onSelected: (value) {
                          themeModeNotifier.value = value;
                          // Same persist mapping as the AppBar theme
                          // controls.
                          Preferences.setThemeMode(switch (value) {
                            ThemeMode.system => 'system',
                            ThemeMode.light => 'light',
                            ThemeMode.dark => 'dark',
                          });
                        },
                      );
                    },
                  );
                  if (c.maxWidth < 520) {
                    // Narrow: the group gets its own full-width line under
                    // the label.
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(alignment: Alignment.centerLeft, child: label),
                        const SizedBox(height: 12),
                        picker,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: label),
                      const SizedBox(width: 16),
                      SizedBox(width: 360, child: picker),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Account & security card on the Settings tab: Security, Hidden & archived
/// items, Server (native builds only), and the confirmed sign-out as the
/// deliberately low-prominence final row. Dumb/injected per house convention;
/// public so widget tests can pump it in isolation.
class SettingsAccountSecurityCard extends StatelessWidget {
  const SettingsAccountSecurityCard({
    super.key,
    required this.onHiddenItemsClosed,
    required this.onSignOut,
    required this.onChangeServer,
  });

  /// Fired when HiddenItemsScreen pops — hiding/unhiding accounts or
  /// holdings changes totals, so the owner must refresh.
  final VoidCallback onHiddenItemsClosed;

  /// Fired only after the user CONFIRMED the sign-out dialog.
  final VoidCallback onSignOut;

  /// Fired only after the user confirmed the change-server dialog. The owner
  /// runs the logout-then-clear sequence.
  final Future<void> Function() onChangeServer;

  Future<void> _confirmChangeServer(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.dashServerChangeTitle),
        content: Text(l.dashServerChangeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            // The consequence the user is accepting is the sign-out, so the
            // confirm button reuses the Security screen's sign-out label.
            child: Text(l.secSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onChangeServer();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: context.tealAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  l.dashAccountSecurityTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shield_outlined),
              title: Text(l.dashSecurity),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SecurityScreen())),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(l.dashHiddenItems),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const HiddenItemsScreen()),
                );
                onHiddenItemsClosed();
              },
            ),
            // Native builds configure the backend URL at first run; this row
            // keeps that setting reachable afterwards. Web derives the URL
            // from its own origin, so there's nothing to change there.
            if (!kIsWeb)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(l.dashServerLabel),
                subtitle: Text(BackendConfig.baseUrl ?? ''),
                onTap: () => _confirmChangeServer(context),
              ),
            const Divider(),
            // Sign out — deliberately the final, low-prominence row, always
            // behind a confirmation.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout, color: scheme.error),
              title: Text(l.dashSignOut, style: TextStyle(color: scheme.error)),
              onTap: () async {
                if (await confirmSignOutDialog(context)) onSignOut();
              },
            ),
          ],
        ),
      ),
    );
  }
}
