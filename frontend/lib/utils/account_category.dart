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
  if (t.contains('mortgage') ||
      t.contains('loan') ||
      t.contains('student') ||
      t.contains('auto')) {
    return AccountCategory.loan;
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
