import 'transaction_description.dart';

/// Pick the best human-readable label for a transaction, walking a
/// preference ladder:
///
///   0. `user_description`      — explicit per-row override the user
///                                 typed in. Wins over every Plaid
///                                 field because if they bothered to
///                                 rename a row, that's the truth they
///                                 want to see. Not run through the
///                                 case/separator normaliser — what
///                                 they typed is what shows.
///   1. `counterparty_name`     — Plaid's enriched merchant entity.
///   2. `merchant_name`         — Plaid's older single-string merchant.
///   3. `original_description`  — raw bank line, only when the cleaned
///                                 `description` is short and generic
///                                 (≤ 22 chars).
///   4. `description`           — Plaid's cleaned `name`. The default.
///
/// Plaid-side strings are run through [cleanTransactionDescription] to
/// normalise case, drop POS reference codes, etc. Raw values are
/// preserved on the transaction map — only the *display* string is
/// derived here. Clearing `user_description` reverts to the auto pick.
String displayLabel(Map<String, dynamic> tx) {
  String? nonEmpty(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  // User-supplied override wins — exact text, no normalisation.
  final userDescription = nonEmpty(tx['user_description']);
  if (userDescription != null) return userDescription;

  final counterparty = nonEmpty(tx['counterparty_name']);
  if (counterparty != null) return cleanTransactionDescription(counterparty);

  final merchant = nonEmpty(tx['merchant_name']);
  if (merchant != null) return cleanTransactionDescription(merchant);

  final desc = nonEmpty(tx['description']);
  final orig = nonEmpty(tx['original_description']);

  // Short, generic `description` ("Miscellaneous Debit",
  // "Miscellaneous Credit", "ACH DEBIT", "POS PURCHASE") — prefer the
  // raw bank line when we have one.
  if (desc != null && orig != null && desc.length <= 22) {
    return cleanTransactionDescription(orig);
  }

  if (desc != null) return cleanTransactionDescription(desc);
  if (orig != null) return cleanTransactionDescription(orig);
  return 'Unknown';
}

/// Counterparty logo URL if Plaid provided one. Always validated to be
/// a non-empty https URL so the frontend Image widget never fails on a
/// bad scheme.
String? counterpartyLogo(Map<String, dynamic> tx) {
  final raw = tx['counterparty_logo_url'];
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  if (!s.startsWith('https://')) return null;
  return s;
}
