/// Pretty-print Plaid's Personal Finance Category enum codes.
///
/// Plaid emits a two-level taxonomy:
///   primary  — coarse bucket, e.g. "LOAN_PAYMENTS"
///   detailed — specific, e.g. "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"
/// The detailed enum is much more useful — "Credit card payment" reads
/// like a human label instead of the all-caps screaming Plaid taxonomy.
///
/// The function prefers user_category (set by the user in the editor),
/// then category_detailed, then category, then falls back to a generic
/// "Uncategorized". Output is sentence-cased and uses curated labels
/// for the cases where the auto-generated string would read awkwardly.
String prettyCategory({
  String? userCategory,
  String? detailed,
  String? primary,
}) {
  final u = (userCategory ?? '').trim();
  if (u.isNotEmpty) return u;

  final d = (detailed ?? '').trim();
  final p = (primary ?? '').trim();
  if (d.isEmpty && p.isEmpty) return 'Uncategorized';

  // 1. Explicit overrides for the cases where the auto-generated label
  //    would still read poorly. Most detailed enums fall through to the
  //    derived form below.
  const overrides = <String, String>{
    // Primary
    'LOAN_PAYMENTS': 'Loan payment',
    'TRANSFER_IN': 'Transfer in',
    'TRANSFER_OUT': 'Transfer out',
    'GENERAL_MERCHANDISE': 'Shopping',
    'GENERAL_SERVICES': 'Services',
    'FOOD_AND_DRINK': 'Food & drink',
    'RENT_AND_UTILITIES': 'Rent & utilities',
    'GOVERNMENT_AND_NON_PROFIT': 'Government & non-profit',
    'PERSONAL_CARE': 'Personal care',
    'HOME_IMPROVEMENT': 'Home improvement',
    'BANK_FEES': 'Bank fees',
    // Detailed — only the most common ones that benefit from a hand
    // tuned label; the rest fall through to the strip-prefix logic.
    'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT': 'Credit card payment',
    'LOAN_PAYMENTS_PERSONAL_LOAN_PAYMENT': 'Personal loan payment',
    'LOAN_PAYMENTS_CAR_PAYMENT': 'Car payment',
    'LOAN_PAYMENTS_MORTGAGE_PAYMENT': 'Mortgage payment',
    'LOAN_PAYMENTS_STUDENT_LOAN_PAYMENT': 'Student loan payment',
    'TRANSFER_IN_DEPOSIT': 'Deposit',
    'TRANSFER_IN_ACCOUNT_TRANSFER': 'Account transfer',
    'TRANSFER_IN_SAVINGS': 'From savings',
    'TRANSFER_OUT_ACCOUNT_TRANSFER': 'Account transfer',
    'TRANSFER_OUT_SAVINGS': 'To savings',
    'TRANSFER_OUT_WITHDRAWAL': 'Withdrawal',
    'TRANSFER_OUT_TRANSFER_OUT_FROM_APPS': 'App payment',
    'TRANSFER_OUT_INVESTMENT_AND_RETIREMENT_FUNDS': 'To investments',
    'TRANSFER_OUT_OTHER_TRANSFER_OUT': 'Outgoing transfer',
    'TRANSFER_IN_TRANSFER_IN_FROM_APPS': 'App deposit',
    'TRANSFER_IN_INVESTMENT_AND_RETIREMENT_FUNDS': 'From investments',
    'TRANSFER_IN_OTHER_TRANSFER_IN': 'Incoming transfer',
    'OTHER': 'Other',
    'OTHER_OTHER': 'Other',
    'INCOME_WAGES': 'Wages',
    'INCOME_INTEREST_EARNED': 'Interest earned',
    'INCOME_DIVIDENDS': 'Dividends',
    'INCOME_RETIREMENT_PENSION': 'Retirement / pension',
    'INCOME_TAX_REFUND': 'Tax refund',
    'FOOD_AND_DRINK_RESTAURANT': 'Restaurants',
    'FOOD_AND_DRINK_FAST_FOOD': 'Fast food',
    'FOOD_AND_DRINK_COFFEE': 'Coffee',
    'FOOD_AND_DRINK_GROCERIES': 'Groceries',
    'FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR': 'Beer, wine & liquor',
    'GENERAL_MERCHANDISE_ONLINE_MARKETPLACES': 'Online marketplaces',
    'GENERAL_MERCHANDISE_CLOTHING_AND_ACCESSORIES': 'Clothing',
    'GENERAL_MERCHANDISE_ELECTRONICS': 'Electronics',
    'GENERAL_MERCHANDISE_DEPARTMENT_STORES': 'Department stores',
    'TRANSPORTATION_GAS': 'Gas',
    'TRANSPORTATION_PARKING': 'Parking',
    'TRANSPORTATION_PUBLIC_TRANSIT': 'Public transit',
    'TRANSPORTATION_TAXIS_AND_RIDE_SHARES': 'Rideshare',
    'TRAVEL_FLIGHTS': 'Flights',
    'TRAVEL_LODGING': 'Lodging',
    'BANK_FEES_OVERDRAFT_FEES': 'Overdraft fee',
    'BANK_FEES_ATM_FEES': 'ATM fee',
    'BANK_FEES_FOREIGN_TRANSACTION_FEES': 'Foreign transaction fee',
    'RENT_AND_UTILITIES_RENT': 'Rent',
    'RENT_AND_UTILITIES_INTERNET_AND_CABLE': 'Internet & cable',
    'RENT_AND_UTILITIES_TELEPHONE': 'Phone',
    'RENT_AND_UTILITIES_GAS_AND_ELECTRICITY': 'Gas & electric',
    'RENT_AND_UTILITIES_WATER': 'Water',
    'ENTERTAINMENT_VIDEO_AND_AUDIO_MEDIA': 'Streaming',
    'PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS': 'Gym & fitness',
    'PERSONAL_CARE_HAIR_AND_BEAUTY': 'Hair & beauty',
  };

  final key = d.isNotEmpty ? d : p;
  final override = overrides[key];
  if (override != null) return override;

  // 2. If we have a detailed code that starts with the primary's prefix,
  //    strip the prefix so we don't say "Loan payments loan payment".
  //    "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" minus "LOAN_PAYMENTS_" leaves
  //    "CREDIT_CARD_PAYMENT" → "Credit card payment".
  if (d.isNotEmpty && p.isNotEmpty && d.startsWith('${p}_')) {
    return _sentence(d.substring(p.length + 1));
  }

  // 3. Otherwise sentence-case whichever code we have.
  return _sentence(key);
}

String _sentence(String s) {
  if (s.isEmpty) return s;
  final lower = s.toLowerCase().replaceAll('_', ' ');
  return lower[0].toUpperCase() + lower.substring(1);
}
