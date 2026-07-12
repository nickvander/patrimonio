// Shared Plaid-OAuth type, used by both the web and native implementations.

/// A persisted in-flight Link session, restored after an OAuth redirect.
/// [mode] decides what onSuccess does on return: `'link'` exchanges the public
/// token for a new institution; `'reconnect'` just re-syncs an existing one.
typedef PendingPlaidOAuth = ({String token, String mode});
