import 'dart:js_interop';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'l10n/app_localizations.dart';
import 'utils/app_locale.dart';
import 'screens/auth_gate.dart';
import 'services/preferences.dart';
import 'theme/palette.dart';
import 'theme/typography.dart';

/// Notifies the app when the user flips the theme. Held at module scope so
/// the AppBar toggle can call `themeModeNotifier.value = ...` from
/// anywhere without threading a callback through every screen.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(_loadInitialThemeMode());

// localeNotifier now lives in utils/app_locale.dart (web-free) so pure-Dart
// code can read the active locale; main() seeds it below.

Locale? _loadInitialLocale() {
  final code = Preferences.getLocale();
  return code == null ? null : Locale(code);
}

ThemeMode _loadInitialThemeMode() {
  switch (Preferences.getThemeMode()) {
    case 'light':
      return ThemeMode.light;
    case 'system':
      return ThemeMode.system;
    case 'dark':
    default:
      return ThemeMode.dark;
  }
}

@JS('__splashProgress')
external void _splashProgress(int percent, String message);

@JS('__splashDone')
external void _splashDone();

void _updateSplash(int percent, String message) {
  if (kIsWeb) {
    try {
      _splashProgress(percent, message);
    } catch (_) {}
  }
}

void _dismissSplash() {
  if (kIsWeb) {
    try {
      _splashDone();
    } catch (_) {}
  }
}

void main() {
  _updateSplash(60, 'Starting app…');
  // Seed the active locale (web-free notifier) from the saved preference.
  localeNotifier.value = _loadInitialLocale();
  // The notifier's listener only fires on *change*; with no saved language
  // the value stays null and Intl would never be initialized, so sync the
  // startup path explicitly (idempotent when the listener already ran).
  syncIntlLocale(localeNotifier.value);
  runApp(const PatrimonioApp());
}

class PatrimonioApp extends StatefulWidget {
  const PatrimonioApp({super.key});

  @override
  State<PatrimonioApp> createState() => _PatrimonioAppState();
}

class _PatrimonioAppState extends State<PatrimonioApp> {
  @override
  void initState() {
    super.initState();
    _updateSplash(80, 'Rendering UI…');
    // Dismiss the HTML splash after Flutter paints its first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateSplash(100, 'Ready');
      _dismissSplash();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (ctx, mode, _) {
        return ValueListenableBuilder<Locale?>(
          valueListenable: localeNotifier,
          builder: (ctx2, locale, __) {
            return MaterialApp(
              title: 'Patrimonio',
              debugShowCheckedModeBanner: false,
              themeMode: mode,
              theme: _buildLightTheme(),
              darkTheme: _buildDarkTheme(),
              // Material animates ThemeData chrome over 200ms by default;
              // 360ms with easeInOutCubic feels less jarring when the user
              // flips brightness and gives non-themed widgets time to fade
              // out (see _ThemeCrossFade in dashboard_screen.dart).
              themeAnimationDuration: const Duration(milliseconds: 360),
              themeAnimationCurve: Curves.easeInOutCubic,
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const AuthGate(),
            );
          },
        );
      },
    );
  }

  // The original dark theme — kept as-is. Most of the in-app components
  // hardcode `Colors.white` so this ColorScheme is what they were tuned
  // against; preserving it avoids visual regressions.
  ThemeData _buildDarkTheme() {
    const b = Brightness.dark;
    return ThemeData(
      brightness: b,
      colorScheme: ColorScheme.fromSeed(
        // Agave jade seed + heritage terracotta/gold overrides, per
        // market_research §4. BrandPalette is the single source of truth.
        seedColor: BrandPalette.seed(b),
        brightness: b,
        surface: BrandPalette.cardSurface(b),
        secondary: BrandPalette.terracotta(b),
        tertiary: BrandPalette.gold(b),
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: BrandPalette.scaffoldBackground(b),
      textTheme: buildBrandTextTheme(ThemeData.dark().textTheme),
      cardTheme: CardThemeData(
        color: BrandPalette.cardSurface(b),
        elevation: 4,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      // AppBar foreground is set explicitly so icon buttons in the
      // actions slot are guaranteed-visible. Without `foregroundColor`,
      // `iconTheme` and `actionsIconTheme`, M3 falls back to
      // colorScheme-derived values that — with a heavily-seeded brand
      // palette on top of the custom dark surface — were rendering the
      // Security and Sign-out icons close to the AppBar background.
      appBarTheme: const AppBarTheme(
        // Warm green-black scaffold colour + warm off-white foreground so
        // the AppBar sits in the same neutral ramp as the body.
        backgroundColor: Color(0xFF10140F),
        foregroundColor: Color(0xFFECEFEA),
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: Color(0xFFECEFEA)),
        actionsIconTheme: IconThemeData(color: Color(0xFFECEFEA)),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStateProperty.all(Colors.black12),
        dataRowColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }

  // Companion light theme. Tuned against the same brand accents as the
  // dark theme but with a slightly cooler surface palette (pure white
  // cards against an off-white scaffold) and noticeably more elevation
  // so cards read as discrete surfaces rather than blending into the
  // background.
  ThemeData _buildLightTheme() {
    const b = Brightness.light;
    final scheme = ColorScheme.fromSeed(
      // Agave jade seed + heritage terracotta/gold, warm-bone raised
      // surface. Per market_research §4; BrandPalette is the source of truth.
      seedColor: BrandPalette.seed(b),
      brightness: b,
      surface: BrandPalette.cardSurface(b),
      surfaceContainerHighest: BrandPalette.elevatedSurface(b),
      secondary: BrandPalette.terracotta(b),
      tertiary: BrandPalette.gold(b),
    );
    return ThemeData(
      brightness: b,
      colorScheme: scheme,
      useMaterial3: true,
      // Warm parchment scaffold so the white cards sit on warmth (not the
      // old cool off-white). Pure white-on-white would merge with cards.
      scaffoldBackgroundColor: BrandPalette.scaffoldBackground(b),
      textTheme: buildBrandTextTheme(ThemeData.light().textTheme),
      cardTheme: CardThemeData(
        color: Colors.white,
        // elevation 2 + a slightly stronger shadow gives cards real
        // separation; elevation 1 / black12 was too timid.
        elevation: 2,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      // Match the dark theme's explicit icon-theme treatment so the
      // Security and Sign-out actions stay readable in both modes —
      // `foregroundColor` alone doesn't always propagate to the
      // IconButtons sitting in the actions slot under M3.
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        // Near-black with a green undertone (#1C2421) — the heritage text
        // primary — instead of the old cool near-black.
        foregroundColor: Color(0xFF1C2421),
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: Color(0xFF1C2421)),
        actionsIconTheme: IconThemeData(color: Color(0xFF1C2421)),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor:
            WidgetStateProperty.all(BrandPalette.elevatedSurface(b)),
        dataRowColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}
