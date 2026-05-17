import 'package:flutter/material.dart';
import 'package:plaid_flutter/plaid_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:web/web.dart' as web;

class ConnectBankScreen extends StatefulWidget {
  const ConnectBankScreen({super.key});

  @override
  State<ConnectBankScreen> createState() => _ConnectBankScreenState();
}

class _ConnectBankScreenState extends State<ConnectBankScreen> {
  bool _isLoading = false;
  Map<String, dynamic>? _setupStatus;

  @override
  void initState() {
    super.initState();
    _loadSetupStatus();
  }

  Future<void> _loadSetupStatus() async {
    final host = web.window.location.hostname.isEmpty
        ? 'localhost'
        : web.window.location.hostname;
    try {
      final response = await http.get(
        Uri.parse('http://$host:8080/api/setup/status'),
      );
      if (response.statusCode == 200 && mounted) {
        setState(() => _setupStatus = json.decode(response.body));
      }
    } catch (_) {
      // Link-token call still handles the actionable error.
    }
  }

  Future<void> _startPlaidLink() async {
    setState(() => _isLoading = true);

    // Dynamically detect host to support VM/Docker test networks correctly
    final host = web.window.location.hostname.isEmpty
        ? 'localhost'
        : web.window.location.hostname;

    try {
      final response = await http.post(
        Uri.parse('http://$host:8080/api/institutions/link-token'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final linkToken = data['link_token'];

        LinkTokenConfiguration linkTokenConfiguration = LinkTokenConfiguration(
          token: linkToken,
        );

        PlaidLink.onSuccess.listen(_onSuccess);
        PlaidLink.onEvent.listen(_onEvent);
        PlaidLink.onExit.listen(_onExit);
        PlaidLink.create(configuration: linkTokenConfiguration);
        PlaidLink.open();
      } else {
        _showError(_responseError(response, 'Failed to retrieve link token'));
      }
    } catch (e) {
      _showError('Error connecting to backend: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onSuccess(LinkSuccess event) async {
    setState(() => _isLoading = true);
    try {
      final String publicToken = event.publicToken;
      final String institutionName =
          event.metadata.institution?.name ?? 'Unknown institution';

      final host = web.window.location.hostname.isEmpty
          ? 'localhost'
          : web.window.location.hostname;

      final response = await http.post(
        Uri.parse('http://$host:8080/api/institutions/exchange-token'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'public_token': publicToken,
          'institution_name': institutionName,
          'institution_type': 'banking', // Generic fallback type for Phase 2
        }),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bank connected. Initial sync has started.'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        _showError(_responseError(response, 'Failed to exchange token'));
      }
    } catch (e) {
      _showError('Error communicating with backend: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _responseError(http.Response response, String fallback) {
    try {
      final data = json.decode(response.body);
      final details = data['details'] ?? data['error'];
      if (details != null) {
        return '$fallback: $details';
      }
    } catch (_) {
      // Keep fallback below.
    }
    return '$fallback: HTTP ${response.statusCode}';
  }

  void _onEvent(LinkEvent event) {
    debugPrint("Plaid Event: ${event.name}");
  }

  void _onExit(LinkExit event) {
    debugPrint("Plaid Exit status: ${event.metadata.status}");
    if (event.error != null) {
      _showError('Plaid Error: ${event.error?.message}');
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect bank'), centerTitle: true),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_setupStatus != null) ...[
                  _buildEnvBanner(_setupStatus!['plaid_environment']),
                  const SizedBox(height: 24),
                ],
                if (_setupStatus?['ready_for_plaid_linking'] == false) ...[
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 42,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Plaid setup is incomplete.',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Set Plaid credentials and ENCRYPTION_KEY before linking real bank accounts.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                ],
                _isLoading
                    ? const CircularProgressIndicator()
                    : ElevatedButton.icon(
                        icon: const Icon(Icons.account_balance),
                        label: const Text('Connect with Plaid'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          textStyle: const TextStyle(fontSize: 18),
                        ),
                        onPressed:
                            _setupStatus?['ready_for_plaid_linking'] == false
                            ? null
                            : _startPlaidLink,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEnvBanner(String env) {
    Color color;
    String text;
    IconData icon;

    switch (env) {
      case 'sandbox':
        color = Colors.blueGrey;
        text = 'Plaid Sandbox Mode — Mock data only';
        icon = Icons.science;
        break;
      case 'development':
        color = Colors.indigo;
        text = 'Plaid Development Mode — Real account data (test items)';
        icon = Icons.developer_mode;
        break;
      case 'production':
        color = Colors.teal;
        text = 'Plaid Production Mode — Real account data';
        icon = Icons.verified_user;
        break;
      default:
        color = Colors.grey;
        text = 'Plaid Environment: $env';
        icon = Icons.info_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color.withValues(alpha: 0.9),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
