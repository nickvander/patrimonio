import 'dart:js_interop';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/auth_gate.dart';
import 'services/preferences.dart';

/// Notifies the app when the user flips the theme. Held at module scope so
/// the AppBar toggle can call `themeModeNotifier.value = ...` from
/// anywhere without threading a callback through every screen.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(_loadInitialThemeMode());

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
          home: const AuthGate(),
        );
      },
    );
  }

  // The original dark theme — kept as-is. Most of the in-app components
  // hardcode `Colors.white` so this ColorScheme is what they were tuned
  // against; preserving it avoids visual regressions.
  ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00E676),
        brightness: Brightness.dark,
        surface: const Color(0xFF1A1A24),
      ),
      useMaterial3: true,
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A1A24),
        elevation: 4,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF101016),
        elevation: 0,
        centerTitle: false,
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
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00A352),
      brightness: Brightness.light,
      surface: Colors.white,
      surfaceContainerHighest: const Color(0xFFEEF0F4),
    );
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: scheme,
      useMaterial3: true,
      // Off-white scaffold gives the white cards somewhere to "sit"
      // visually. Pure white-on-white merges them with the AppBar.
      scaffoldBackgroundColor: const Color(0xFFEDEFF3),
      textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
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
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF101016),
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStateProperty.all(const Color(0xFFEEF0F4)),
        dataRowColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}
