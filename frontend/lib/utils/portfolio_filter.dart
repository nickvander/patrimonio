import '../l10n/app_localizations.dart';

/// True when holding [h] passes the allocation-band filter [filter].
///
/// The allocation heatmap emits dimension-prefixed values (contract C3) —
/// `asset:<canonical class>`, `account_type:<raw type>`,
/// `institution:<raw name>` — and each prefix matches ONLY its own field.
/// `asset:` keys on the backend's canonical `asset_class` (contract C2), so
/// a VBTLX-style bond *mutual fund* lands under `asset:bonds` and a holding
/// inside a bonds-typed *account* no longer matches everything. A bare
/// value (no colon before the first space, or an unknown prefix) falls back
/// to the legacy any-field OR so the card keeps filtering if the emitter
/// and parser ship at different times. Matching is case-insensitive.
/// Top-level (not a method) so tests can exercise the parsing directly.
bool holdingMatchesCategoryFilter(Map h, String? filter) {
  final catFilter = (filter ?? '').toLowerCase().trim();
  if (catFilter.isEmpty) return true;
  String field(String key) => (h[key] ?? '').toString().toLowerCase();
  final colon = catFilter.indexOf(':');
  final space = catFilter.indexOf(' ');
  if (colon > 0 && (space == -1 || colon < space)) {
    final value = catFilter.substring(colon + 1).trim();
    switch (catFilter.substring(0, colon)) {
      case 'asset':
        return field('asset_class') == value;
      case 'account_type':
        return field('account_type') == value;
      case 'institution':
        return field('institution_name') == value;
      // Unknown prefix: fall through to the legacy any-field match below.
    }
  }
  return field('holding_type') == catFilter ||
      field('account_type') == catFilter ||
      field('institution_name') == catFilter;
}

/// Human label for the active-filter chip / zero-result state: strips the
/// C3 dimension prefix and title-cases the value ("asset:bonds" → "Bonds",
/// "institution:vanguard" → "Vanguard"). Bare legacy values are only
/// title-cased.
///
/// When [l] is given, `asset:` canonical keys (contract C2) render as the
/// same display names the allocation band shows (the backend's
/// `asset_class_label` mapping) — "asset:equity" must echo the tapped
/// "Stocks & funds" band, not a raw "Equity". Unknown keys keep the
/// title-cased fallback.
String categoryFilterLabel(String filter, [AppLocalizations? l]) {
  var value = filter.trim();
  final colon = value.indexOf(':');
  final space = value.indexOf(' ');
  if (colon > 0 && (space == -1 || colon < space)) {
    final dim = value.substring(0, colon).toLowerCase();
    const dims = {'asset', 'account_type', 'institution'};
    if (dims.contains(dim)) {
      value = value.substring(colon + 1).trim();
      if (dim == 'asset' && l != null) {
        final assetLabel = switch (value.toLowerCase()) {
          'equity' => l.pfFilterAssetEquity,
          'bonds' => l.pfFilterAssetBonds,
          'cash' => l.pfFilterAssetCash,
          'crypto' => l.pfFilterAssetCrypto,
          'real_estate' => l.pfFilterAssetRealEstate,
          'commodities' => l.pfFilterAssetCommodities,
          'other' => l.pfFilterAssetOther,
          _ => null,
        };
        if (assetLabel != null) return assetLabel;
      }
    }
  }
  return value
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
