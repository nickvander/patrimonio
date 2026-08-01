import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/backend_config.dart';
import '../utils/app_locale.dart';

/// What the connectivity probe found at the entered URL.
enum _Preflight { ok, unreachable, cfAccessBlocked, notPatrimonio }

/// First-run (and "change server") screen for native builds: the user enters
/// the URL of their self-hosted Patrimonio backend. We normalise it, do a quick
/// connectivity pre-flight against `/api/auth/status`, and persist it via
/// [BackendConfig] — which flips [RootGate] over to the auth flow.
///
/// Native-only, so it uses the web-free [localeNotifier]-based `_t` helper for
/// en/es-MX rather than AppLocalizations (no new .arb strings needed).
class BackendSetupScreen extends StatefulWidget {
  const BackendSetupScreen({super.key});

  @override
  State<BackendSetupScreen> createState() => _BackendSetupScreenState();
}

class _BackendSetupScreenState extends State<BackendSetupScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: BackendConfig.baseUrl ?? 'https://',
  );
  late final TextEditingController _cfId = TextEditingController(
    text: BackendConfig.cfAccessClientId ?? '',
  );
  late final TextEditingController _cfSecret = TextEditingController(
    text: BackendConfig.cfAccessClientSecret ?? '',
  );
  // Start expanded when a token is already stored (editing an existing setup).
  late bool _advancedOpen = BackendConfig.hasCfAccessToken;
  bool _busy = false;
  String? _error;

  static String _t(String en, String es) =>
      localeNotifier.value?.languageCode == 'es' ? es : en;

  @override
  void dispose() {
    _controller.dispose();
    _cfId.dispose();
    _cfSecret.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final raw = _controller.text.trim();
    final formatError = BackendConfig.validationError(raw);
    if (formatError != null) {
      setState(() => _error = formatError);
      return;
    }
    final cfId = _cfId.text.trim();
    final cfSecret = _cfSecret.text.trim();
    if ((cfId.isEmpty) != (cfSecret.isEmpty)) {
      setState(() {
        _error = _t(
          'Enter BOTH the Access client ID and secret, or leave both empty.',
          'Ingresa AMBOS: el ID de cliente de Access y el secreto, o deja '
              'ambos vacíos.',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final origin = BackendConfig.normalize(raw);
    final result = await _preflight(origin, cfId: cfId, cfSecret: cfSecret);
    if (!mounted) return;

    if (result != _Preflight.ok) {
      setState(() {
        _busy = false;
        _error = switch (result) {
          _Preflight.cfAccessBlocked => _t(
            'That server is protected by Cloudflare Access. Open '
                '"Advanced" below and enter a CF Access service token '
                '(client ID + secret), or ask the server admin for one.',
            'Ese servidor está protegido por Cloudflare Access. Abre '
                '"Avanzado" abajo e ingresa un token de servicio de CF Access '
                '(ID de cliente + secreto), o pídelo al administrador.',
          ),
          _Preflight.notPatrimonio => _t(
            'Reached that address, but it doesn\'t answer like a '
                'Patrimonio backend. Check the URL.',
            'Se alcanzó esa dirección, pero no responde como un servidor '
                'de Patrimonio. Revisa la URL.',
          ),
          _ => _t(
            "Couldn't reach that backend. Check the URL, that the server "
                'is running, and that this device can reach it.',
            'No se pudo conectar con ese servidor. Revisa la URL, que el '
                'servidor esté en ejecución y que este dispositivo pueda '
                'alcanzarlo.',
          ),
        };
        if (result == _Preflight.cfAccessBlocked && !_advancedOpen) {
          _advancedOpen = true;
        }
      });
      return;
    }

    // Persist + flip the gate. AuthGate mounts next and checks auth status.
    await BackendConfig.save(
      origin,
      cfClientId: cfId,
      cfClientSecret: cfSecret,
    );
    // No setState after this — the widget is being replaced by RootGate.
  }

  /// Probe `/api/auth/status` and classify what answered:
  ///
  /// - **ok** — the body parses as JSON (any HTTP status: a signed-out user
  ///   still gets a well-formed JSON reply).
  /// - **cfAccessBlocked** — an HTML answer that smells like the Cloudflare
  ///   Access login interstitial (redirect chain lands on
  ///   `*.cloudflareaccess.com`, or CF Access markers in the body). Native
  ///   apps can't do that browser login, so surface the service-token hint.
  /// - **notPatrimonio** — reachable, but some other non-JSON thing answered.
  /// - **unreachable** — socket error / timeout.
  Future<_Preflight> _preflight(
    String origin, {
    required String cfId,
    required String cfSecret,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse('$origin/api/auth/status'));
      if (cfId.isNotEmpty && cfSecret.isNotEmpty) {
        req.headers['CF-Access-Client-Id'] = cfId;
        req.headers['CF-Access-Client-Secret'] = cfSecret;
      }
      final streamed = await client
          .send(req)
          .timeout(const Duration(seconds: 8));
      final res = await http.Response.fromStream(streamed);
      try {
        jsonDecode(res.body);
        return _Preflight.ok;
      } catch (_) {
        final finalUrl = (streamed.request?.url ?? req.url)
            .toString()
            .toLowerCase();
        final body = res.body.toLowerCase();
        if (finalUrl.contains('cloudflareaccess.com') ||
            body.contains('cloudflareaccess.com') ||
            body.contains('cf_challenge') ||
            res.headers['cf-access-aud'] != null) {
          return _Preflight.cfAccessBlocked;
        }
        return _Preflight.notPatrimonio;
      }
    } catch (_) {
      return _Preflight.unreachable;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Patrimonio',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _t('Connect to your backend', 'Conéctate a tu servidor'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _controller,
                    enabled: !_busy,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _busy ? null : _connect(),
                    decoration: InputDecoration(
                      labelText: _t('Backend URL', 'URL del servidor'),
                      hintText: 'https://patrimonio.example.com',
                      prefixIcon: const Icon(Icons.dns_outlined),
                      border: const OutlineInputBorder(),
                      errorText: _error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _t(
                      'Enter the address where your Patrimonio server is '
                          'hosted. HTTPS is strongly recommended.',
                      'Ingresa la dirección donde está alojado tu servidor '
                          'Patrimonio. Se recomienda encarecidamente HTTPS.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Optional Cloudflare Access service token — only needed
                  // when the backend sits behind Cloudflare Zero Trust.
                  // Collapsed by default so the common "just a URL" case
                  // stays one-field simple.
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    initiallyExpanded: _advancedOpen,
                    onExpansionChanged: (open) =>
                        setState(() => _advancedOpen = open),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(
                      _t(
                        'Advanced: Cloudflare Access',
                        'Avanzado: Cloudflare Access',
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                    childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
                    children: [
                      Text(
                        _t(
                          'Only needed if the server is behind Cloudflare '
                              'Access (Zero Trust). Paste a service token — the '
                              'app sends it as CF-Access-Client-Id / '
                              'CF-Access-Client-Secret on every request.',
                          'Solo se necesita si el servidor está detrás de '
                              'Cloudflare Access (Zero Trust). Pega un token de '
                              'servicio: la app lo envía como '
                              'CF-Access-Client-Id / CF-Access-Client-Secret en '
                              'cada solicitud.',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _cfId,
                        enabled: !_busy,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: _t(
                            'Access client ID',
                            'ID de cliente de Access',
                          ),
                          hintText: '….access',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _cfSecret,
                        enabled: !_busy,
                        autocorrect: false,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: _t(
                            'Access client secret',
                            'Secreto de cliente de Access',
                          ),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(
                      _busy
                          ? _t('Connecting…', 'Conectando…')
                          : _t('Connect', 'Conectar'),
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
