import 'app_locale.dart';

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
  // A user-typed override is their own data — never re-translate it.
  final u = (userCategory ?? '').trim();
  if (u.isNotEmpty) return u;

  // Active UI language (read from the web-free notifier so this stays
  // pure-Dart / test-safe). When Spanish, prefer the es taxonomy below.
  final es = localeNotifier.value?.languageCode == 'es';

  final d = (detailed ?? '').trim();
  final p = (primary ?? '').trim();
  if (d.isEmpty && p.isEmpty) return es ? 'Sin categoría' : 'Uncategorized';

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

  // Hand-tuned es-MX labels, keyed identically to `overrides` (plus a few
  // primary buckets that otherwise fall through to the derived path). Any
  // Plaid code without an es entry falls back to the English override, then
  // to the derived English label — so the common, visible categories are
  // Spanish and only the rare long tail stays English.
  const esOverrides = <String, String>{
    // Primary
    'LOAN_PAYMENTS': 'Pago de préstamo',
    'TRANSFER_IN': 'Transferencia recibida',
    'TRANSFER_OUT': 'Transferencia enviada',
    'GENERAL_MERCHANDISE': 'Compras',
    'GENERAL_SERVICES': 'Servicios',
    'FOOD_AND_DRINK': 'Comida y bebida',
    'RENT_AND_UTILITIES': 'Renta y servicios',
    'GOVERNMENT_AND_NON_PROFIT': 'Gobierno y ONG',
    'PERSONAL_CARE': 'Cuidado personal',
    'HOME_IMPROVEMENT': 'Mejoras al hogar',
    'BANK_FEES': 'Comisiones bancarias',
    'TRANSPORTATION': 'Transporte',
    'TRAVEL': 'Viajes',
    'ENTERTAINMENT': 'Entretenimiento',
    'INCOME': 'Ingresos',
    'MEDICAL': 'Salud',
    // Detailed
    'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT': 'Pago de tarjeta de crédito',
    'LOAN_PAYMENTS_PERSONAL_LOAN_PAYMENT': 'Pago de préstamo personal',
    'LOAN_PAYMENTS_CAR_PAYMENT': 'Pago de auto',
    'LOAN_PAYMENTS_MORTGAGE_PAYMENT': 'Pago de hipoteca',
    'LOAN_PAYMENTS_STUDENT_LOAN_PAYMENT': 'Pago de préstamo estudiantil',
    'TRANSFER_IN_DEPOSIT': 'Depósito',
    'TRANSFER_IN_ACCOUNT_TRANSFER': 'Transferencia entre cuentas',
    'TRANSFER_IN_SAVINGS': 'Desde ahorros',
    'TRANSFER_OUT_ACCOUNT_TRANSFER': 'Transferencia entre cuentas',
    'TRANSFER_OUT_SAVINGS': 'A ahorros',
    'TRANSFER_OUT_WITHDRAWAL': 'Retiro',
    'TRANSFER_OUT_TRANSFER_OUT_FROM_APPS': 'Pago por app',
    'TRANSFER_OUT_INVESTMENT_AND_RETIREMENT_FUNDS': 'A inversiones',
    'TRANSFER_OUT_OTHER_TRANSFER_OUT': 'Transferencia saliente',
    'TRANSFER_IN_TRANSFER_IN_FROM_APPS': 'Depósito por app',
    'TRANSFER_IN_INVESTMENT_AND_RETIREMENT_FUNDS': 'Desde inversiones',
    'TRANSFER_IN_OTHER_TRANSFER_IN': 'Transferencia entrante',
    'OTHER': 'Otros',
    'OTHER_OTHER': 'Otros',
    'INCOME_WAGES': 'Salario',
    'INCOME_INTEREST_EARNED': 'Intereses ganados',
    'INCOME_DIVIDENDS': 'Dividendos',
    'INCOME_RETIREMENT_PENSION': 'Jubilación / pensión',
    'INCOME_TAX_REFUND': 'Devolución de impuestos',
    'FOOD_AND_DRINK_RESTAURANT': 'Restaurantes',
    'FOOD_AND_DRINK_FAST_FOOD': 'Comida rápida',
    'FOOD_AND_DRINK_COFFEE': 'Café',
    'FOOD_AND_DRINK_GROCERIES': 'Supermercado',
    'FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR': 'Cerveza, vino y licor',
    'GENERAL_MERCHANDISE_ONLINE_MARKETPLACES': 'Tiendas en línea',
    'GENERAL_MERCHANDISE_CLOTHING_AND_ACCESSORIES': 'Ropa',
    'GENERAL_MERCHANDISE_ELECTRONICS': 'Electrónica',
    'GENERAL_MERCHANDISE_DEPARTMENT_STORES': 'Tiendas departamentales',
    'TRANSPORTATION_GAS': 'Gasolina',
    'TRANSPORTATION_PARKING': 'Estacionamiento',
    'TRANSPORTATION_PUBLIC_TRANSIT': 'Transporte público',
    'TRANSPORTATION_TAXIS_AND_RIDE_SHARES': 'Viajes compartidos',
    'TRAVEL_FLIGHTS': 'Vuelos',
    'TRAVEL_LODGING': 'Hospedaje',
    'BANK_FEES_OVERDRAFT_FEES': 'Comisión por sobregiro',
    'BANK_FEES_ATM_FEES': 'Comisión de cajero',
    'BANK_FEES_FOREIGN_TRANSACTION_FEES':
        'Comisión por transacción internacional',
    'RENT_AND_UTILITIES_RENT': 'Renta',
    'RENT_AND_UTILITIES_INTERNET_AND_CABLE': 'Internet y cable',
    'RENT_AND_UTILITIES_TELEPHONE': 'Teléfono',
    'RENT_AND_UTILITIES_GAS_AND_ELECTRICITY': 'Gas y electricidad',
    'RENT_AND_UTILITIES_WATER': 'Agua',
    'ENTERTAINMENT_VIDEO_AND_AUDIO_MEDIA': 'Streaming',
    'PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS': 'Gimnasio y fitness',
    'PERSONAL_CARE_HAIR_AND_BEAUTY': 'Belleza y peluquería',
  };

  final key = d.isNotEmpty ? d : p;
  final override = es ? (esOverrides[key] ?? overrides[key]) : overrides[key];
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

/// Distinct prettified category labels present in [transactions], sorted
/// case-insensitively. The single source for category suggestion lists
/// (the Activity tab's set-category autocomplete and the Add-transaction
/// dialog, wherever it's opened from) so suggestions reflect the
/// categories the user actually has instead of a fixed taxonomy that
/// drifts over time — and so the Home quick-add FAB can offer the same
/// list without the Activity tab being mounted.
List<String> distinctPrettyCategories(List<dynamic> transactions) {
  final set = <String>{};
  for (final t in transactions) {
    if (t is! Map) continue;
    final cat = prettyCategory(
      userCategory: t['user_category']?.toString(),
      detailed: t['category_detailed']?.toString(),
      primary: t['category']?.toString(),
    );
    if (cat.isNotEmpty) set.add(cat);
  }
  final list = set.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}
