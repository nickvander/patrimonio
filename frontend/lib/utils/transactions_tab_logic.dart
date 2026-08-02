/// Pure, widget-free logic for the Transactions tab.
///
/// Extracted from `transactions_tab.dart` so the detail-panel save
/// diffing, the search haystack, and the running-balance arithmetic can
/// be unit-tested without pumping the tab. The tab (and its tests) call
/// straight into these.
library;

import 'transaction_display.dart';

/// Detail-panel Save diffing: returns the trimmed edited text when it
/// genuinely differs from the prefilled [initial] value, or null when
/// the field is unchanged so the caller omits it from the PATCH
/// entirely (null = "leave this column alone" in
/// `ApiService.updateTransaction`).
///
/// The comparison is against the exact prefill — for the category field
/// that's the PRETTIFIED label the editor was seeded with, so opening a
/// transaction and pressing Save without edits never converts the
/// auto-category into a user override of the raw Plaid enum string.
/// Clearing a prefilled field IS a change and returns '' (the backend
/// treats an empty string as "clear the override").
///
/// Top-level (not a method) so the no-op-Save behavior is unit-testable
/// without pumping the detail panel.
String? diffEditedField(String edited, String initial) {
  final next = edited.trim();
  return next == initial.trim() ? null : next;
}

/// Trailing ".00" / "0" trimmer for the haystack's plain amount form.
/// Hoisted so [searchHaystackFor] doesn't rebuild the RegExp per row.
final RegExp _trailingZeros = RegExp(r'\.?0+$');

/// Lowercased search haystack for one transaction: every text field a
/// user can see on the row or in its detail panel — including
/// `user_notes`, which is rendered right in the row's meta line — plus
/// the amount in plain numeric forms. The amount is the absolute value
/// as both "450.00" and "450" (trailing zeros trimmed), so searching
/// "450" or "450.00" finds a 450.00 transaction regardless of the
/// storage sign convention (negative = outflow; see backend
/// services/sync.rs:659) or how the row formats the currency.
///
/// Top-level (not a method) so the field list is unit-testable without
/// pumping the tab; [TransactionsTabState._haystackFor] wraps it with
/// the per-list-identity memoization.
String searchHaystackFor(Map<String, dynamic> tx) {
  final label = displayLabel(tx).toLowerCase();
  final parts = <String>[
    label,
    (tx['description'] ?? '').toString().toLowerCase(),
    (tx['original_description'] ?? '').toString().toLowerCase(),
    (tx['merchant_name'] ?? '').toString().toLowerCase(),
    (tx['counterparty_name'] ?? '').toString().toLowerCase(),
    (tx['payment_payee'] ?? '').toString().toLowerCase(),
    (tx['payment_payer'] ?? '').toString().toLowerCase(),
    (tx['account_name'] ?? '').toString().toLowerCase(),
    (tx['category'] ?? '').toString().toLowerCase(),
    (tx['user_notes'] ?? '').toString().toLowerCase(),
  ];
  final amount = (tx['amount'] as num?)?.toDouble();
  if (amount != null) {
    final fixed = amount.abs().toStringAsFixed(2); // "450.00"
    parts.add(fixed);
    // "450" for 450.00, "450.5" for 450.50 — contains() already lets
    // a "450" query hit "450.00", but the trimmed form also lets a
    // "450 " style exact token read naturally in the haystack.
    final plain = fixed.replaceFirst(_trailingZeros, '');
    if (plain.isNotEmpty && plain != fixed) parts.add(plain);
  }
  // Single concatenated string — one .contains() call covers
  // every field. Separator is a 4-char printable sequence that
  // users virtually never type into a search field, so cross-
  // field false positives are negligible while git keeps treating
  // the file as plain text.
  return parts.join(' || ');
}

/// Per-row "balance after this transaction" for the single-account
/// panel, keyed by transaction id.
///
/// The input list must be newest-first and contiguous from the top of
/// the account's history — exactly what the per-account fetch returns
/// (it always pages from offset 0), so the loaded window satisfies
/// this by construction.
///
/// Per row:
/// - A persisted `balance_after` (statement imports carry the bank's
///   own SALDO column) always wins — it's exact — and re-anchors the
///   walk for the older rows beneath it.
/// - Otherwise the value is ESTIMATED by walking down from [anchor]
///   (the account's current native-currency balance): the top row's
///   balance-after IS the anchor, and each step down removes the newer
///   row's amount (storage sign convention, see backend
///   services/sync.rs:659: negative = outflow, positive = inflow, so
///   `balance_after = balance_before + amount`, i.e.
///   `balance_before = balance_after − amount`). No anchor → no
///   estimates.
/// - A row whose amount is missing/unparseable breaks the walk: every
///   row below it gets NO estimate (persisted values still show, and
///   re-anchor) — better to show nothing than a wrong number.
///
/// Top-level (not a method) so the arithmetic is unit-testable without
/// pumping the tab; the widget wraps it with identity-keyed memoization.
Map<String, ({double value, bool estimated})> runningBalancesFor(
  List<dynamic> transactions, {
  double? anchor,
}) {
  final out = <String, ({double value, bool estimated})>{};
  // Balance after the CURRENT row as we walk down the list; null once
  // the walk has become unsound (no anchor yet, or a gap above).
  double? running = anchor;
  for (final tx in transactions) {
    if (tx is! Map) {
      running = null;
      continue;
    }
    final id = tx['id']?.toString();
    final persisted = (tx['balance_after'] as num?)?.toDouble();
    final amount = (tx['amount'] as num?)?.toDouble();
    if (persisted != null) {
      if (id != null && id.isNotEmpty) {
        out[id] = (value: persisted, estimated: false);
      }
      // Exact statement balance re-anchors the walk below.
      running = persisted;
    } else if (running != null && id != null && id.isNotEmpty) {
      out[id] = (value: running, estimated: true);
    }
    // Step down: the next (older) row's balance-after is this row's
    // balance-before, i.e. balance_after − amount (a negative outflow
    // REDUCED the balance, so before it the balance was higher). An
    // unparseable amount poisons everything below.
    running = (running == null || amount == null) ? null : running - amount;
  }
  return out;
}
