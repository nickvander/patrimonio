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
        _showError('Failed to retrieve link token: ${response.statusCode}');
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
          event.metadata.institution?.name ?? 'Unknown Institution';

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
              content: Text('Bank connected successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        _showError('Failed to exchange token: ${response.body}');
      }
    } catch (e) {
      _showError('Error communicating with backend: $e');
    } finally {
      setState(() => _isLoading = false);
    }
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
      appBar: AppBar(title: const Text('Connect Bank'), centerTitle: true),
      body: Center(
        child: _isLoading
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
                onPressed: _startPlaidLink,
              ),
      ),
    );
  }
}
