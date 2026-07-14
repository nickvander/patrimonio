import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:plaid_flutter/plaid_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/api_platform.dart';
import '../services/plaid_oauth.dart';
import '../utils/theme_colors.dart';

class ConnectBankScreen extends StatefulWidget {
  const ConnectBankScreen({super.key});

  @override
  State<ConnectBankScreen> createState() => _ConnectBankScreenState();
}

class _ConnectBankScreenState extends State<ConnectBankScreen> {
  // Credentialed client, NOT package:http's top-level functions: on native
  // only this client's shared jar attaches the session cookie (the browser
  // does it for free on web) — raw http.get/post made every request here
  // anonymous on Android, so the link-token fetch 401'd.
  final http.Client _http = createApiClient();
  bool _isLoading = false;
  Map<String, dynamic>? _setupStatus;

  // PlaidLink broadcast-stream subscriptions. Re-running the link flow would
  // otherwise stack a second set of handlers onto the same streams; track them
  // so each run replaces the previous and dispose() cleans them up.
  final List<StreamSubscription<dynamic>> _plaidSubs = [];

  @override
  void initState() {
    super.initState();
    _loadSetupStatus();
  }

  @override
  void dispose() {
    for (final s in _plaidSubs) {
      s.cancel();
    }
    _http.close();
    super.dispose();
  }

  Future<void> _loadSetupStatus() async {
    try {
      final response = await _http.get(
        Uri.parse('${apiBaseUrl()}/setup/status'),
        headers: apiExtraHeaders(),
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

    try {
      final response = await _http.post(
        Uri.parse('${apiBaseUrl()}/institutions/link-token'),
        headers: {
          'Content-Type': 'application/json',
          'X-Requested-With': 'fetch',
          ...apiExtraHeaders(),
        },
        // OAuth banks need a platform-appropriate return target: Android
        // gets android_package_name (the Plaid SDK intercepts the OAuth
        // return in-app); web keeps the https redirect_uri. Without this,
        // an Android OAuth link completes in the browser and the public
        // token never reaches the app.
        body: json.encode({
          'platform': kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final linkToken = data['link_token'];

        // Replace any handlers from a previous run so a single Plaid event
        // doesn't fire _onSuccess/_onExit N times after N taps.
        for (final s in _plaidSubs) {
          s.cancel();
        }
        _plaidSubs
          ..clear()
          ..add(PlaidLink.onSuccess.listen(_onSuccess))
          ..add(PlaidLink.onEvent.listen(_onEvent))
          ..add(PlaidLink.onExit.listen(_onExit));
        // Persist the token before opening so an OAuth bank that navigates the
        // tab away and back can resume the same session (see plaid_oauth.dart).
        // For non-OAuth banks this is a no-op beyond a localStorage write —
        // _onSuccess fires in-tab as before.
        openPlaidLink(linkToken);
      } else {
        if (!mounted) return;
        _showError(_responseError(
            response, AppLocalizations.of(context).cbLinkTokenFailed));
      }
    } catch (e) {
      if (!mounted) return;
      _showError(AppLocalizations.of(context).cbBackendConnectError(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSuccess(LinkSuccess event) async {
    setState(() => _isLoading = true);
    try {
      final String publicToken = event.publicToken;
      final String institutionName =
          event.metadata.institution?.name ?? 'Unknown institution';

      final response = await _http.post(
        Uri.parse('${apiBaseUrl()}/institutions/exchange-token'),
        headers: {
          'Content-Type': 'application/json',
          'X-Requested-With': 'fetch',
          ...apiExtraHeaders(),
        },
        body: json.encode({
          'public_token': publicToken,
          'institution_name': institutionName,
          'institution_type': 'banking', // Generic fallback type for Phase 2
        }),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).cbConnected),
              backgroundColor: context.positive,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        if (!mounted) return;
        _showError(_responseError(
            response, AppLocalizations.of(context).cbExchangeTokenFailed));
      }
    } catch (e) {
      if (!mounted) return;
      _showError(AppLocalizations.of(context).cbBackendCommError(e.toString()));
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
    if (mounted) {
      return AppLocalizations.of(context)
          .cbHttpError(fallback, response.statusCode);
    }
    return '$fallback: HTTP ${response.statusCode}';
  }

  void _onEvent(LinkEvent event) {
    debugPrint("Plaid Event: ${event.name}");
  }

  void _onExit(LinkExit event) {
    debugPrint("Plaid Exit status: ${event.metadata.status}");
    if (event.error != null && mounted) {
      _showError(AppLocalizations.of(context)
          .cbPlaidError(event.error?.message ?? ''));
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: context.negative),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.cbTitle), centerTitle: true),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_setupStatus != null) ...[
                  _buildEnvBanner(l, _setupStatus!['plaid_environment']),
                  const SizedBox(height: 24),
                ],
                if (_setupStatus?['ready_for_plaid_linking'] == false) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 42,
                    color: context.warning,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.cbSetupIncompleteTitle,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.cbSetupIncompleteBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.textMuted),
                  ),
                  const SizedBox(height: 24),
                ],
                _isLoading
                    ? const CircularProgressIndicator()
                    : ElevatedButton.icon(
                        icon: const Icon(Icons.account_balance),
                        label: Text(l.cbConnectWithPlaid),
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

  Widget _buildEnvBanner(AppLocalizations l, String env) {
    Color color;
    String text;
    IconData icon;

    switch (env) {
      case 'sandbox':
        color = context.neutralAccent;
        text = l.cbEnvSandbox;
        icon = Icons.science;
        break;
      case 'development':
        color = context.info;
        text = l.cbEnvDevelopment;
        icon = Icons.developer_mode;
        break;
      case 'production':
        color = context.tealAccent;
        text = l.cbEnvProduction;
        icon = Icons.verified_user;
        break;
      default:
        color = context.textSubtle;
        text = l.cbEnvUnknown(env);
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
