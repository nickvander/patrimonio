import 'package:flutter/material.dart';

import 'palette.dart';

/// House chrome for every floating menu surface, so popups, anchored menus
/// and dropdowns read as one family: card surface (no M3 elevation tint),
/// 12px corners, dialog-tier elevation with the house `black26` shadow, and
/// the Inter body style with enough line height for wrapped labels.
///
/// Three different Flutter menu systems are in play and only two of them
/// have ThemeData hooks:
///
///  * [PopupMenuButton] / [showMenu] → [buildPopupMenuTheme], installed as
///    `ThemeData.popupMenuTheme` in `main.dart`.
///  * [MenuAnchor] / [MenuItemButton] → [buildMenuTheme], installed as
///    `ThemeData.menuTheme` in `main.dart`.
///  * The legacy dropdown route behind [DropdownButton] /
///    [DropdownButtonFormField] has NO theme hook for its menu surface or
///    corner radius — each call site must pass `dropdownColor:` +
///    `borderRadius:` explicitly. [houseDropdownColor] and [kMenuRadius] are
///    the single source of truth for those per-site params; never inline a
///    color or radius at a dropdown site.
///
/// Width cap: popup menus keep the framework's 280dp max width (5 × the
/// 56dp step) — there is no theme hook for it, and it is already the same
/// everywhere. Long labels wrap inside that cap; the `height: 1.35` label
/// style below is what keeps multi-line items readable.

/// Corner radius shared by all menu surfaces.
const BorderRadius kMenuRadius = BorderRadius.all(Radius.circular(12));

/// Menus sit on the dialog overlay tier: the M3 dialog default elevation
/// (6) with the house `black26` shadow used by cards.
const double _menuElevation = 6;

/// Popup-menu chrome for [PopupMenuButton] / [showMenu].
PopupMenuThemeData buildPopupMenuTheme(
  Brightness brightness,
  ColorScheme scheme,
  TextTheme textTheme,
) {
  // House body type for menu labels. `height` gives wrapped long labels
  // (e.g. the transactions kebab's cross-currency scan entry) breathing
  // room; custom children with their own styles are unaffected.
  final label = textTheme.bodyMedium!.copyWith(
    color: scheme.onSurface,
    height: 1.35,
  );
  return PopupMenuThemeData(
    color: BrandPalette.cardSurface(brightness),
    // Kill the M3 elevation tint so the menu shows the card surface
    // verbatim (the tint is what made stock menus read greenish).
    surfaceTintColor: Colors.transparent,
    elevation: _menuElevation,
    shadowColor: Colors.black26,
    shape: const RoundedRectangleBorder(borderRadius: kMenuRadius),
    menuPadding: const EdgeInsets.symmetric(vertical: 8),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? label.copyWith(color: scheme.onSurface.withValues(alpha: 0.38))
          : label,
    ),
  );
}

/// Anchored-menu chrome for [MenuAnchor] menus (e.g. the Security screen's
/// "Add passkey" menu). Item text is styled by the items themselves, so
/// this only carries the surface chrome.
MenuThemeData buildMenuTheme(Brightness brightness) {
  return MenuThemeData(
    style: MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        BrandPalette.cardSurface(brightness),
      ),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(_menuElevation),
      shadowColor: const WidgetStatePropertyAll(Colors.black26),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: kMenuRadius),
      ),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
    ),
  );
}

/// Menu surface for the legacy dropdown route — pass as `dropdownColor:`
/// on every [DropdownButton] / [DropdownButtonFormField], paired with
/// `borderRadius: kMenuRadius` (see the library doc above for why this
/// cannot be themed centrally).
Color houseDropdownColor(BuildContext context) =>
    BrandPalette.cardSurface(Theme.of(context).brightness);
