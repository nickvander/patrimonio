import 'transaction_description.dart';

/// Generic Plaid / bank "name" strings that carry no information.
/// When the row's `description` matches one of these (case-insensitive,
/// trimmed, optionally prefix-matched), the display ladder skips past
/// it and prefers any other identifier we have.
///
/// Kept as a single-word prefix list so "Miscellaneous Debit",
/// "miscellaneous credit", "Miscellaneous credit 20260418" all match
/// — banks occasionally append a date or reference code without
/// changing the leading token.
const _genericDescriptionPrefixes = <String>[
  'miscellaneous',
  'ach debit',
  'ach credit',
  'ach payment',
  'ach withdrawal',
  'ach deposit',
  'pos purchase',
  'pos debit',
  'pos credit',
  'online banking',
  'online transfer',
  'wire transfer',
  'transfer in',
  'transfer out',
  'bank transfer',
  'bill payment',
  'electronic payment',
  'electronic withdrawal',
  'direct deposit',
  'debit',
  'credit',
  'withdrawal',
  'deposit',
];

bool _looksGeneric(String s) {
  final lower = s.trim().toLowerCase();
  if (lower.isEmpty) return true;
  for (final prefix in _genericDescriptionPrefixes) {
    if (lower == prefix || lower.startsWith('$prefix ')) return true;
  }
  return false;
}

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
///   3. `payment_payee` / `payment_payer` — Plaid `payment_meta`. The
///                                 only useful identifier on most
///                                 ACH / wire / bill-pay rows. Use payee
///                                 for outflows, payer for inflows.
///   4. `original_description`  — raw bank line. Preferred over the
///                                 cleaned `description` whenever the
///                                 latter is one of the known-generic
///                                 prefixes (see `_genericDescriptionPrefixes`).
///   5. `description`           — Plaid's cleaned `name`. The default.
///
/// Plaid-side strings are run through [cleanTransactionDescription] to
/// normalise case, drop POS reference codes, etc. — but ONLY for rows
/// whose `source` is not 'manual'. A manual row's description is the
/// user's own typed words: re-casing it ("CRITIC TEST coffee" →
/// "Critic TEST coffee") silently rewrote user input, so manual rows
/// display verbatim. Raw values are preserved on the transaction map —
/// only the *display* string is derived here. Clearing
/// `user_description` reverts to the auto pick.
String displayLabel(Map<String, dynamic> tx) {
  String? nonEmpty(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  // Manual entries are user-authored text, never bank noise — the
  // normaliser must not touch them.
  final isManual = (tx['source'] ?? '').toString() == 'manual';
  String clean(String s) => isManual ? s : cleanTransactionDescription(s);

  // User-supplied override wins — exact text, no normalisation.
  final userDescription = nonEmpty(tx['user_description']);
  if (userDescription != null) return userDescription;

  final counterparty = nonEmpty(tx['counterparty_name']);
  if (counterparty != null) return clean(counterparty);

  final merchant = nonEmpty(tx['merchant_name']);
  if (merchant != null) return clean(merchant);

  final desc = nonEmpty(tx['description']);
  final orig = nonEmpty(tx['original_description']);
  // Storage sign convention (backend sync.rs:659): amount < 0 is an
  // outflow (expense). We prefer payee for outflows and payer for
  // inflows; if only one side is populated we fall through to it
  // regardless of sign.
  final amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
  final payee = nonEmpty(tx['payment_payee']);
  final payer = nonEmpty(tx['payment_payer']);
  final paymentSide = amount < 0
      ? (payee ?? payer)
      : (payer ?? payee);

  if (desc != null && _looksGeneric(desc)) {
    // Skip past the generic description in favour of any specific
    // identifier we have. Ordered: payment_meta → original_description
    // → the generic description as a last resort.
    if (paymentSide != null) return clean(paymentSide);
    if (orig != null && !_looksGeneric(orig)) {
      return clean(orig);
    }
  }

  if (desc != null) return clean(desc);
  if (paymentSide != null) return clean(paymentSide);
  if (orig != null) return clean(orig);
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
