import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'bootstrap_screen.dart';
import 'dashboard_screen.dart';
import 'login_screen.dart';
import 'register_screen.dart';
import 'totp_challenge_screen.dart';

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
    // Invitation redemption is encoded as `?invite=<token>`. When the
    // user is signed-out (not bootstrapped, not signed-in) and a
    // token is present, route to the register flow instead of the
    // login screen. Once they sign in, AuthGate flips to signedIn
    // and the dashboard takes over — the param can stay in the URL.
    final inviteToken = Uri.base.queryParameters['invite']?.trim();
    final hasInvite = inviteToken != null && inviteToken.isNotEmpty;

    switch (_state.phase) {
      case AuthPhase.unknown:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthPhase.needsBootstrap:
        return const BootstrapScreen();
      case AuthPhase.signedOut:
        if (hasInvite) {
          return RegisterScreen(inviteToken: inviteToken);
        }
        return const LoginScreen();
      case AuthPhase.awaitingTotp:
        return const TotpChallengeScreen();
      case AuthPhase.signedIn:
        return const DashboardScreen();
    }
  }
}
