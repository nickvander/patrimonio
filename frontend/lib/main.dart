import 'package:flutter/material.dart';
import 'screens/connect_bank_screen.dart';

void main() {
  runApp(const PatrimonioApp());
}

class PatrimonioApp extends StatelessWidget {
  const PatrimonioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Patrimonio',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Patrimonio Dashboard'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text(
              'Welcome to Patrimonio! 🚀',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => ConnectBankScreen()),
                );
              },
              child: const Text('Add Linked Account'),
            ),
          ],
        ),
      ),
    );
  }
}
