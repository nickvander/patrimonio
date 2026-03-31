import 'dart:js_interop';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/dashboard_screen.dart';

@JS('__splashProgress')
external void _splashProgress(int percent, String message);

@JS('__splashDone')
external void _splashDone();

void _updateSplash(int percent, String message) {
  if (kIsWeb) {
    try { _splashProgress(percent, message); } catch (_) {}
  }
}

void _dismissSplash() {
  if (kIsWeb) {
    try { _splashDone(); } catch (_) {}
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
    return MaterialApp(
      title: 'Patrimonio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676), // Emerald green accent
          brightness: Brightness.dark,
          surface: const Color(0xFF1A1A24), // Softer dark card background
          background: const Color(0xFF101016), // Softer main background
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1A24),
          elevation: 4,
          shadowColor: Colors.black26,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101016),
          elevation: 0,
          centerTitle: false,
        ),
        dataTableTheme: DataTableThemeData(
          headingRowColor: MaterialStateProperty.all(Colors.black12),
          dataRowColor: MaterialStateProperty.all(Colors.transparent),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
