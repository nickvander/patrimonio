import 'transaction_description.dart';

/// Pick the best human-readable label for a transaction, walking a
/// preference ladder of Plaid-provided fields:
///
///   1. `counterparty_name`     — Plaid's enriched merchant entity. When
///                                 present this is usually the right
///                                 answer ("Patagonia", "Spotify").
///   2. `merchant_name`         — Plaid's older single-string merchant
///                                 field. Less reliable than the
///                                 counterparties array but better than
///                                 a generic `name`.
///   3. `original_description`  — the raw bank line. We only fall back
///                                 to this when the cleaned
///                                 `description` is short and generic
///                                 (≤ 22 chars) — long descriptions
///                                 from the bank usually contain real
///                                 information already.
///   4. `description`           — Plaid's cleaned `name`. The current
///                                 default — used when nothing better
///                                 is available.
///
/// All chosen strings are then run through [cleanTransactionDescription]
/// to normalise case, drop POS reference codes, etc. The raw values are
/// preserved on the transaction map — only the *display* string is
/// derived here.
String displayLabel(Map<String, dynamic> tx) {
  String? nonEmpty(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

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
