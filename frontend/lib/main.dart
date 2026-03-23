import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/dashboard_screen.dart';

void main() {
  runApp(const PatrimonioApp());
}

class PatrimonioApp extends StatelessWidget {
  const PatrimonioApp({super.key});

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
