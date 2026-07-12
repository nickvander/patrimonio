import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/backend_config.dart';
import 'auth_gate.dart';
import 'backend_setup_screen.dart';

/// Top-of-tree gate that runs *before* auth.
///
/// On the web the backend is same-origin (derived from `window.location`), so
/// there is nothing to configure — go straight to [AuthGate]. On a native build
/// (the APK) the user must first tell the app which self-hosted backend to talk
/// to; until they do, show [BackendSetupScreen]. Saving a URL updates
/// [BackendConfig.baseUrlNotifier], which rebuilds this widget and mounts
/// [AuthGate] — whose `initState` then checks auth status against that backend.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const AuthGate();
    return ValueListenableBuilder<String?>(
      valueListenable: BackendConfig.baseUrlNotifier,
      builder: (context, baseUrl, _) {
        if (baseUrl == null || baseUrl.isEmpty) {
          return const BackendSetupScreen();
        }
        return const AuthGate();
      },
    );
  }
}
