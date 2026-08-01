import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// Central category → (icon, color) registry for the transactions surfaces.
///
/// Why this exists: the old `_getCategoryIcon` / `_getCategoryColor` helpers
/// in `transactions_tab.dart` substring-matched ENGLISH keywords ("food",
/// "travel", "starbucks") and returned raw Material constants
/// (`Colors.orange`, `Colors.grey`, …). Any user-typed or Spanish category —
/// i.e. most of what the statement importer produces for the core audience —
/// fell through to grey `Icons.receipt`, so the icon column conveyed nothing,
/// and the raw Material hues clashed with the jade/heritage palette and
/// ignored brightness.
///
/// Design:
///  • Keyed on the PRETTIFIED label (the output of `prettyCategory` in
///    `utils/category.dart`), lower-cased. Both the English and the es-MX
///    label for each Plaid PFC bucket map to the same style, so the icon
///    stays put when the user flips the UI language.
///  • The vocabulary is sourced from the real strings the app produces:
///    the PFC primary codes the importer emits
///    (`backend/src/services/categorize.rs` — BANK_FEES, INCOME, FOOD_AND_DRINK,
///    TRANSPORTATION, TRAVEL, MEDICAL, PERSONAL_CARE, ENTERTAINMENT,
///    HOME_IMPROVEMENT, GENERAL_MERCHANDISE, GENERAL_SERVICES,
///    RENT_AND_UTILITIES, LOAN_PAYMENTS, GOVERNMENT_AND_NON_PROFIT,
///    TRANSFER_IN/OUT) plus the common detailed labels from
///    `prettyCategory`'s en/es override maps.
///  • Colors come from `BrandPalette`, so every style is brightness-aware:
///    same hue family in both themes, neon-leaning shade on the dark
///    green-black surfaces, darker AA-passing shade on the parchment/white
///    surfaces. That light/dark shade shift is intended — identity is the
///    hue family, not the exact ARGB value.
///  • Unknown labels (free-typed user categories, rare long-tail Plaid
///    codes) get a STABLE color from a curated list of brand-harmonious
///    hues via an FNV-1a hash of the normalized label — never grey. Only
///    the explicit "Uncategorized"/"Otros"-style buckets use the neutral
///    token, deliberately, because "no signal" is their meaning.
class CategoryStyle {
  final IconData icon;
  final Color color;
  const CategoryStyle(this.icon, this.color);
}

/// Convenience accessor that resolves against the active theme brightness,
/// mirroring the `context.positive` / `context.textMuted` pattern in
/// `utils/theme_colors.dart`.
extension CategoryStyleContext on BuildContext {
  CategoryStyle categoryStyle(String? prettyLabel) =>
      categoryStyleFor(prettyLabel, Theme.of(this).brightness);
}

/// Resolve the (icon, color) style for a prettified category label.
///
/// Pure function (no BuildContext) so it's unit-testable without pumping
/// widgets. Deterministic: the same label + brightness always returns the
/// identical style.
CategoryStyle categoryStyleFor(String? prettyLabel, Brightness brightness) {
  final key = (prettyLabel ?? '').trim().toLowerCase();
  if (key.isEmpty) {
    // No category at all — neutral on purpose (this is the one "honestly
    // no signal" case, same treatment as the explicit Uncategorized key).
    return CategoryStyle(_uncategorizedIcon, BrandPalette.neutral(brightness));
  }
  final spec = _registry[key];
  if (spec != null) {
    return CategoryStyle(spec.icon, spec.color(brightness));
  }
  // Unknown label → stable brand-harmonious hue, generic label icon.
  final hues = categoryFallbackPalette(brightness);
  return CategoryStyle(_fallbackIcon, hues[_fnv1a(key) % hues.length]);
}

/// Curated brand-harmonious hues for the deterministic fallback. Built from
/// the `BrandPalette` accents + chart-series ramp so a free-typed category
/// sits in the same visual family as the explicit mappings. Grey/neutral is
/// deliberately excluded — an unknown category must still read as *a*
/// category.
@visibleForTesting
List<Color> categoryFallbackPalette(Brightness b) => [
  BrandPalette.terracotta(b),
  BrandPalette.gold(b),
  BrandPalette.info(b),
  BrandPalette.teal(b),
  BrandPalette.pink(b),
  BrandPalette.purple(b),
  BrandPalette.yellow(b),
  _azure(b),
  _cyan(b),
  _ember(b),
];

const IconData _fallbackIcon = Icons.label_outline;
const IconData _uncategorizedIcon = Icons.receipt_long_outlined;

// Chart-series hues reused as named accents so the registry below stays
// readable. Index into BrandPalette.chartSeries: 0 azure, 3 deep orange,
// 4 cyan, 5 rose.
Color _azure(Brightness b) => BrandPalette.chartSeries(b)[0];
Color _ember(Brightness b) => BrandPalette.chartSeries(b)[3];
Color _cyan(Brightness b) => BrandPalette.chartSeries(b)[4];
Color _rose(Brightness b) => BrandPalette.chartSeries(b)[5];

class _Spec {
  final IconData icon;
  final Color Function(Brightness) color;
  const _Spec(this.icon, this.color);
}

/// Explicit label → style mappings. Keys are the lower-cased output of
/// `prettyCategory` — the English override/derived labels AND the es-MX
/// labels, side by side. Hue families:
///   income → jade (positive)        transfers → cyan
///   food & drink → terracotta       transport → lake blue (info)
///   travel → azure                  shopping → purple
///   services/subscriptions → teal   entertainment → pink
///   rent & utilities / home → amber (warning)
///   loans/cards → heritage gold     bank fees → ember (deep orange)
///   medical → rose                  personal care → teal
///   government → neutral            other/uncategorized → neutral
const Map<String, _Spec> _registry = {
  // --- Income (INCOME + detailed) — gains are the brand, so jade. -----------
  'income': _Spec(Icons.trending_up, BrandPalette.positive),
  'ingresos': _Spec(Icons.trending_up, BrandPalette.positive),
  'wages': _Spec(Icons.payments_outlined, BrandPalette.positive),
  'salario': _Spec(Icons.payments_outlined, BrandPalette.positive),
  'interest earned': _Spec(Icons.percent, BrandPalette.positive),
  'intereses ganados': _Spec(Icons.percent, BrandPalette.positive),
  'dividends': _Spec(Icons.area_chart_outlined, BrandPalette.positive),
  'dividendos': _Spec(Icons.area_chart_outlined, BrandPalette.positive),
  'retirement / pension': _Spec(Icons.savings_outlined, BrandPalette.positive),
  'jubilación / pensión': _Spec(Icons.savings_outlined, BrandPalette.positive),
  'tax refund': _Spec(
    Icons.replay_circle_filled_outlined,
    BrandPalette.positive,
  ),
  'devolución de impuestos': _Spec(
    Icons.replay_circle_filled_outlined,
    BrandPalette.positive,
  ),

  // --- Transfers (TRANSFER_IN / TRANSFER_OUT + detailed) --------------------
  'transfer in': _Spec(Icons.call_received, _cyan),
  'transferencia recibida': _Spec(Icons.call_received, _cyan),
  'transfer out': _Spec(Icons.call_made, _cyan),
  'transferencia enviada': _Spec(Icons.call_made, _cyan),
  'incoming transfer': _Spec(Icons.call_received, _cyan),
  'transferencia entrante': _Spec(Icons.call_received, _cyan),
  'outgoing transfer': _Spec(Icons.call_made, _cyan),
  'transferencia saliente': _Spec(Icons.call_made, _cyan),
  'account transfer': _Spec(Icons.sync_alt, _cyan),
  'transferencia entre cuentas': _Spec(Icons.sync_alt, _cyan),
  'deposit': _Spec(Icons.account_balance, _cyan),
  'depósito': _Spec(Icons.account_balance, _cyan),
  'withdrawal': _Spec(Icons.local_atm, _cyan),
  'retiro': _Spec(Icons.local_atm, _cyan),
  'from savings': _Spec(Icons.savings_outlined, _cyan),
  'desde ahorros': _Spec(Icons.savings_outlined, _cyan),
  'to savings': _Spec(Icons.savings_outlined, _cyan),
  'a ahorros': _Spec(Icons.savings_outlined, _cyan),
  'app payment': _Spec(Icons.smartphone, _cyan),
  'pago por app': _Spec(Icons.smartphone, _cyan),
  'app deposit': _Spec(Icons.smartphone, _cyan),
  'depósito por app': _Spec(Icons.smartphone, _cyan),
  'to investments': _Spec(Icons.candlestick_chart_outlined, _cyan),
  'a inversiones': _Spec(Icons.candlestick_chart_outlined, _cyan),
  'from investments': _Spec(Icons.candlestick_chart_outlined, _cyan),
  'desde inversiones': _Spec(Icons.candlestick_chart_outlined, _cyan),

  // --- Food & drink (FOOD_AND_DRINK + detailed) — warm terracotta. ----------
  'food & drink': _Spec(Icons.restaurant, BrandPalette.terracotta),
  'comida y bebida': _Spec(Icons.restaurant, BrandPalette.terracotta),
  'restaurants': _Spec(Icons.restaurant, BrandPalette.terracotta),
  'restaurantes': _Spec(Icons.restaurant, BrandPalette.terracotta),
  'fast food': _Spec(Icons.fastfood_outlined, BrandPalette.terracotta),
  'comida rápida': _Spec(Icons.fastfood_outlined, BrandPalette.terracotta),
  'coffee': _Spec(Icons.local_cafe_outlined, BrandPalette.terracotta),
  'café': _Spec(Icons.local_cafe_outlined, BrandPalette.terracotta),
  'groceries': _Spec(Icons.shopping_cart_outlined, BrandPalette.terracotta),
  'supermercado': _Spec(Icons.shopping_cart_outlined, BrandPalette.terracotta),
  'beer, wine & liquor': _Spec(Icons.liquor_outlined, BrandPalette.terracotta),
  'cerveza, vino y licor': _Spec(
    Icons.liquor_outlined,
    BrandPalette.terracotta,
  ),

  // --- Transportation (TRANSPORTATION + detailed) — lake blue. --------------
  'transportation': _Spec(Icons.directions_car_outlined, BrandPalette.info),
  'transporte': _Spec(Icons.directions_car_outlined, BrandPalette.info),
  'gas': _Spec(Icons.local_gas_station_outlined, BrandPalette.info),
  'gasolina': _Spec(Icons.local_gas_station_outlined, BrandPalette.info),
  'parking': _Spec(Icons.local_parking, BrandPalette.info),
  'estacionamiento': _Spec(Icons.local_parking, BrandPalette.info),
  'public transit': _Spec(Icons.directions_bus_outlined, BrandPalette.info),
  'transporte público': _Spec(Icons.directions_bus_outlined, BrandPalette.info),
  'rideshare': _Spec(Icons.local_taxi_outlined, BrandPalette.info),
  'viajes compartidos': _Spec(Icons.local_taxi_outlined, BrandPalette.info),

  // --- Travel (TRAVEL + detailed) — azure. -----------------------------------
  'travel': _Spec(Icons.flight, _azure),
  'viajes': _Spec(Icons.flight, _azure),
  'flights': _Spec(Icons.flight_takeoff, _azure),
  'vuelos': _Spec(Icons.flight_takeoff, _azure),
  'lodging': _Spec(Icons.hotel_outlined, _azure),
  'hospedaje': _Spec(Icons.hotel_outlined, _azure),

  // --- Shopping (GENERAL_MERCHANDISE + detailed) — purple. ------------------
  'shopping': _Spec(Icons.shopping_bag_outlined, BrandPalette.purple),
  'compras': _Spec(Icons.shopping_bag_outlined, BrandPalette.purple),
  'online marketplaces': _Spec(
    Icons.shopping_bag_outlined,
    BrandPalette.purple,
  ),
  'tiendas en línea': _Spec(Icons.shopping_bag_outlined, BrandPalette.purple),
  'clothing': _Spec(Icons.checkroom, BrandPalette.purple),
  'ropa': _Spec(Icons.checkroom, BrandPalette.purple),
  'electronics': _Spec(Icons.devices_other, BrandPalette.purple),
  'electrónica': _Spec(Icons.devices_other, BrandPalette.purple),
  'department stores': _Spec(Icons.storefront, BrandPalette.purple),
  'tiendas departamentales': _Spec(Icons.storefront, BrandPalette.purple),

  // --- Services / subscriptions (GENERAL_SERVICES) — teal. ------------------
  'services': _Spec(Icons.miscellaneous_services_outlined, BrandPalette.teal),
  'servicios': _Spec(Icons.miscellaneous_services_outlined, BrandPalette.teal),

  // --- Entertainment (ENTERTAINMENT + detailed) — pink. ---------------------
  'entertainment': _Spec(Icons.movie_outlined, BrandPalette.pink),
  'entretenimiento': _Spec(Icons.movie_outlined, BrandPalette.pink),
  'streaming': _Spec(Icons.play_circle_outline, BrandPalette.pink),

  // --- Rent & utilities (RENT_AND_UTILITIES + detailed) — amber. ------------
  'rent & utilities': _Spec(Icons.home_outlined, BrandPalette.warning),
  'renta y servicios': _Spec(Icons.home_outlined, BrandPalette.warning),
  'rent': _Spec(Icons.home_outlined, BrandPalette.warning),
  'renta': _Spec(Icons.home_outlined, BrandPalette.warning),
  'internet & cable': _Spec(Icons.wifi, BrandPalette.warning),
  'internet y cable': _Spec(Icons.wifi, BrandPalette.warning),
  'phone': _Spec(Icons.phone_iphone, BrandPalette.warning),
  'teléfono': _Spec(Icons.phone_iphone, BrandPalette.warning),
  'gas & electric': _Spec(Icons.bolt, BrandPalette.warning),
  'gas y electricidad': _Spec(Icons.bolt, BrandPalette.warning),
  'water': _Spec(Icons.water_drop_outlined, BrandPalette.warning),
  'agua': _Spec(Icons.water_drop_outlined, BrandPalette.warning),

  // --- Home improvement — shares the amber "home" family. -------------------
  'home improvement': _Spec(Icons.handyman_outlined, BrandPalette.warning),
  'mejoras al hogar': _Spec(Icons.handyman_outlined, BrandPalette.warning),

  // --- Loans & cards (LOAN_PAYMENTS + detailed) — heritage gold. ------------
  'loan payment': _Spec(Icons.credit_score, BrandPalette.gold),
  'pago de préstamo': _Spec(Icons.credit_score, BrandPalette.gold),
  'credit card payment': _Spec(Icons.credit_card, BrandPalette.gold),
  'pago de tarjeta de crédito': _Spec(Icons.credit_card, BrandPalette.gold),
  'personal loan payment': _Spec(Icons.credit_score, BrandPalette.gold),
  'pago de préstamo personal': _Spec(Icons.credit_score, BrandPalette.gold),
  'car payment': _Spec(Icons.directions_car_filled_outlined, BrandPalette.gold),
  'pago de auto': _Spec(
    Icons.directions_car_filled_outlined,
    BrandPalette.gold,
  ),
  'mortgage payment': _Spec(Icons.house_outlined, BrandPalette.gold),
  'pago de hipoteca': _Spec(Icons.house_outlined, BrandPalette.gold),
  'student loan payment': _Spec(Icons.school_outlined, BrandPalette.gold),
  'pago de préstamo estudiantil': _Spec(
    Icons.school_outlined,
    BrandPalette.gold,
  ),

  // --- Bank fees (BANK_FEES + detailed) — ember. -----------------------------
  'bank fees': _Spec(Icons.receipt_long_outlined, _ember),
  'comisiones bancarias': _Spec(Icons.receipt_long_outlined, _ember),
  'overdraft fee': _Spec(Icons.receipt_long_outlined, _ember),
  'comisión por sobregiro': _Spec(Icons.receipt_long_outlined, _ember),
  'atm fee': _Spec(Icons.local_atm, _ember),
  'comisión de cajero': _Spec(Icons.local_atm, _ember),
  'foreign transaction fee': _Spec(Icons.currency_exchange, _ember),
  'comisión por transacción internacional': _Spec(
    Icons.currency_exchange,
    _ember,
  ),

  // --- Medical (MEDICAL) — rose. ---------------------------------------------
  'medical': _Spec(Icons.medical_services_outlined, _rose),
  'salud': _Spec(Icons.medical_services_outlined, _rose),

  // --- Personal care (PERSONAL_CARE + detailed) — teal. ----------------------
  'personal care': _Spec(Icons.spa_outlined, BrandPalette.teal),
  'cuidado personal': _Spec(Icons.spa_outlined, BrandPalette.teal),
  'gym & fitness': _Spec(Icons.fitness_center, BrandPalette.teal),
  'gimnasio y fitness': _Spec(Icons.fitness_center, BrandPalette.teal),
  'hair & beauty': _Spec(Icons.content_cut, BrandPalette.teal),
  'belleza y peluquería': _Spec(Icons.content_cut, BrandPalette.teal),

  // --- Government & non-profit (GOVERNMENT_AND_NON_PROFIT) -------------------
  'government & non-profit': _Spec(
    Icons.account_balance_outlined,
    BrandPalette.neutral,
  ),
  'gobierno y ong': _Spec(Icons.account_balance_outlined, BrandPalette.neutral),

  // --- Explicit "no signal" buckets — neutral on purpose. --------------------
  'other': _Spec(_fallbackIcon, BrandPalette.neutral),
  'otros': _Spec(_fallbackIcon, BrandPalette.neutral),
  'uncategorized': _Spec(_uncategorizedIcon, BrandPalette.neutral),
  'sin categoría': _Spec(_uncategorizedIcon, BrandPalette.neutral),
};

/// 32-bit FNV-1a over the label's UTF-16 code units. Implemented with a
/// split 16-bit multiply so the arithmetic stays exact under JS number
/// semantics on web — `String.hashCode` is NOT used because Dart doesn't
/// guarantee it's stable across runs/platforms, and the whole point is a
/// color that never changes under the user's feet.
int _fnv1a(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h ^= c;
    final lo = (h & 0xFFFF) * 0x01000193;
    final hi = ((h >> 16) & 0xFFFF) * 0x01000193;
    h = (lo + ((hi & 0xFFFF) << 16)) & 0xFFFFFFFF;
  }
  return h;
}
