// Native (Android/iOS) Plaid Link.
//
// plaid_flutter drives the native Plaid Link SDK directly, so opening Link
// works. The web-only OAuth *resume* dance (persisting the link token across a
// full-page redirect and reading `oauth_state_id` off `window.location`) does
// not apply on native — the native SDK handles OAuth bank redirects internally
// via an app link / universal link configured on the Plaid side. So the
// persistence here is just in-memory and [pendingPlaidOAuth] always returns null
// (there is no page URL to inspect).
import 'package:plaid_flutter/plaid_flutter.dart';

import 'plaid_oauth_types.dart';

/// Open Plaid Link for [linkToken]. [mode] only matters for the web
/// page-reload resume path, which native doesn't use (the SDK handles OAuth
/// returns), so it's accepted for API parity and ignored here.
void openPlaidLink(String linkToken, {String mode = 'link'}) {
  PlaidLink.create(configuration: LinkTokenConfiguration(token: linkToken));
  PlaidLink.open();
}

/// No page-reload OAuth resume on native — always null.
PendingPlaidOAuth? pendingPlaidOAuth() => null;

/// Re-open Link with the same [token]. The native SDK resumes the OAuth
/// handshake itself; there is no received-redirect URL to hand back.
void resumePlaidLink(String token) {
  PlaidLink.create(configuration: LinkTokenConfiguration(token: token));
  PlaidLink.open();
}

/// No persisted session to forget on native.
void clearPlaidOAuth() {}
