import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'bootstrap_screen.dart';
import 'dashboard_screen.dart';
import 'login_screen.dart';

/// Single owner of the top-level routing decision: which screen to
/// show given the current auth state. Listens to AuthService so a
/// 401 from anywhere drops back to login automatically.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthState _state = const AuthState(AuthPhase.unknown);

  @override
  void initState() {
    super.initState();
    AuthService.instance.stream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _state = AuthService.instance.current;
    AuthService.instance.refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    switch (_state.phase) {
      case AuthPhase.unknown:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthPhase.needsBootstrap:
        return const BootstrapScreen();
      case AuthPhase.signedOut:
        return const LoginScreen();
      case AuthPhase.signedIn:
        return const DashboardScreen();
    }
  }
}
