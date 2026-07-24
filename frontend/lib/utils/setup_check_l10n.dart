import '../l10n/app_localizations.dart';

/// Maps a stable setup-check `key` from `/api/setup/status` to its
/// localized label.
///
/// The backend ships an English `label` alongside each key for backward
/// compat with older frontends; that server string is the fallback for
/// any key this build doesn't know, so a newer backend adding a check
/// renders its (English) label instead of a blank row.
String setupCheckLabel(AppLocalizations l, String key, String fallback) {
  switch (key) {
    case 'plaid':
      return l.dashSetupCheckPlaid;
    case 'encryption':
      return l.dashSetupCheckEncryption;
    case 'fx':
      return l.dashSetupCheckFx;
    case 'coinbase':
      return l.dashSetupCheckCoinbase;
    case 'plaid_webhook':
      return l.dashSetupCheckPlaidWebhook;
    case 'cors':
      return l.dashSetupCheckCors;
    default:
      return fallback;
  }
}
