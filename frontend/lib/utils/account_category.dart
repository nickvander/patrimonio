/// Buckets a Plaid `account_type` (or our manual-account equivalents)
/// into one of the high-level categories the dashboard groups by.
///
/// Centralising this means the Overview KPI strip, the accounts column
/// grouping, and any other surface that splits cash vs investments stay
/// in lockstep. Previously each call site had its own list and missed
/// types like `stock plan` (Morgan Stanley StockPlan) or `roth` fell
/// through to the cash fallback.
enum AccountCategory {
  cash,
  investment,
  credit,
  crypto,
  loan,
  /// Non-financial assets that don't sync with a bank or exchange:
  /// real estate, vehicles, collectibles, private-equity stakes. The
  /// user revalues these manually via the per-row "Revalue" action.
  /// Contributes to total Assets / Net worth like any other asset
  /// but renders in its own group on the Accounts column so the
  /// user can find it without scrolling past Cash + Investments.
  realAsset,
  other,
}

AccountCategory categorizeAccount(String? rawType) {
  final t = (rawType ?? '').toLowerCase().trim();
  if (t.isEmpty) return AccountCategory.other;

  // Substring-tolerant matchers so Plaid subtype renamings (`401(k)`,
  // `roth 401k`, `stock plan`, `esop`) keep mapping correctly without
  // an exact-match expansion every time.
  if (t.contains('credit')) return AccountCategory.credit;
  if (t.contains('crypto')) return AccountCategory.crypto;
  // Auto LOANS go into loans, but a bare "auto" or "vehicle" alone is
  // the asset itself — check the loan-side terms first.
  if (t.contains('mortgage') ||
      t.contains('loan') ||
      t.contains('student') ||
      t.contains('auto loan')) {
    return AccountCategory.loan;
  }
  // Non-financial assets the user revalues manually. Match by the
  // substrings the add-account dialog exposes (Real estate, Vehicle,
  // Private equity, Collectibles, Other asset). "Other asset" is the
  // catch-all the user can pick for an LLC stake or angel investment
  // we haven't given a label.
  if (t.contains('real estate') ||
      t.contains('vehicle') ||
      t == 'auto' ||
      t == 'car' ||
      t.contains('private equity') ||
      t.contains('collectible') ||
      t.contains('other asset') ||
      t.contains('property')) {
    return AccountCategory.realAsset;
  }
  if (t.contains('ira') ||
      t.contains('401') ||
      t.contains('403') ||
      t.contains('roth') ||
      t.contains('hsa') ||
      t.contains('brokerage') ||
      t.contains('investment') ||
      t.contains('stock') ||
      t.contains('esop') ||
      t.contains('pension') ||
      t.contains('rsu') ||
      t.contains('mutual') ||
      t.contains('sep') ||
      t.contains('529')) {
    return AccountCategory.investment;
  }
  if (t.contains('checking') ||
      t.contains('savings') ||
      t.contains('money market') ||
      t.contains('cash management') ||
      t == 'cd' ||
      t.contains('cash')) {
    return AccountCategory.cash;
  }
  return AccountCategory.other;
}
