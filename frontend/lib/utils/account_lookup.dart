/// Resolve one account map from the dashboard overview's `accounts` list
/// by id. Returns null when the id is absent (e.g. the account was
/// archived since the payload naming it was produced) so the caller can
/// fall back gracefully instead of opening a panel on a missing account.
Map<String, dynamic>? findAccountById(List<dynamic> accounts, String id) {
  if (id.isEmpty) return null;
  for (final raw in accounts) {
    if (raw is! Map) continue;
    if (raw['id']?.toString() == id) return Map<String, dynamic>.from(raw);
  }
  return null;
}

/// Route a largest-move drill-down: [openPanel] with the resolved account
/// when [accountId] exists in [accounts], else [fallback] (the previous
/// Transactions-tab jump — e.g. the account was archived, or a stale
/// payload names an id the overview no longer carries). Extracted so both
/// sides of the decision are unit-testable without pumping the dashboard.
void routeAccountMoveJump({
  required List<dynamic> accounts,
  required String accountId,
  required void Function(Map<String, dynamic> account) openPanel,
  required void Function() fallback,
}) {
  final account = findAccountById(accounts, accountId);
  if (account != null) {
    openPanel(account);
  } else {
    fallback();
  }
}
