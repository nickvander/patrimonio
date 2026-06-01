import 'dart:convert';
import 'package:plaid_flutter/plaid_flutter.dart';
import 'package:web/web.dart' as web;

// Plaid OAuth banks (Chase, BofA, Wells Fargo, …) bounce the WHOLE browser tab
// out to the bank's own login page and then back to our registered
// `redirect_uri`, carrying an `oauth_state_id` query param. The page reloads
// fresh, so the in-flight link token has to survive the round-trip and Link
// must be re-opened with the return URL handed to Plaid as
// `receivedRedirectUri`. Non-OAuth banks never leave the tab and touch none of
// this — they just complete inline via PlaidLink.onSuccess.

const _storageKey = 'patrimonio:plaid_oauth';

/// A persisted in-flight Link session, restored after the OAuth redirect.
/// [mode] decides what onSuccess does on return: `'link'` exchanges the public
/// token for a new institution; `'reconnect'` just re-syncs an existing one.
typedef PendingPlaidOAuth = ({String token, String mode});

/// Persist [linkToken] (and [mode]) then open Plaid Link. The persistence is
/// what lets [pendingPlaidOAuth] resume the SAME session if an OAuth bank
/// navigates the tab away and back.
void openPlaidLink(String linkToken, {String mode = 'link'}) {
  web.window.localStorage
      .setItem(_storageKey, jsonEncode({'token': linkToken, 'mode': mode}));
  PlaidLink.create(configuration: LinkTokenConfiguration(token: linkToken));
  PlaidLink.open();
}

/// If the current URL is an OAuth return (`oauth_state_id` present) and we have
/// a stored token, return the session to resume; otherwise null.
PendingPlaidOAuth? pendingPlaidOAuth() {
  final uri = Uri.tryParse(web.window.location.href);
  if (uri == null || !uri.queryParameters.containsKey('oauth_state_id')) {
    return null;
  }
  final raw = web.window.localStorage.getItem(_storageKey);
  if (raw == null) return null;
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final token = m['token'];
    if (token is! String) return null;
    return (token: token, mode: (m['mode'] as String?) ?? 'link');
  } catch (_) {
    return null;
  }
}

/// Re-open Link after an OAuth redirect: same [token], with the full return URL
/// handed to Plaid as `receivedRedirectUri` so it can finish the handshake.
void resumePlaidLink(String token) {
  PlaidLink.create(
    configuration: LinkTokenConfiguration(
      token: token,
      receivedRedirectUri: web.window.location.href,
    ),
  );
  PlaidLink.open();
}

/// Forget any stored Link session (call as soon as a resume is under way) so a
/// later cold boot never replays a spent token.
void clearPlaidOAuth() {
  web.window.localStorage.removeItem(_storageKey);
}
