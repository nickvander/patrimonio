/// The house form-field decoration — the "filled, rounded, borderless"
/// input recipe the 2026-08-02 dialog-consistency sweep settled on.
///
/// WHY THIS EXISTS: the sweep standardised the recipe but landed it as a
/// private `_fieldDecoration` copied into each panel it touched
/// (`add_transaction_dialog.dart`, `add_account_dialog.dart`,
/// `add_crypto_dialog.dart`, `add_recurring_rule_dialog.dart`,
/// `quick_entry_sheet.dart`). Everything it did NOT touch — the split
/// editor, the three lending panels — kept a fourth and fifth style
/// (`OutlineInputBorder()` at radius 8/10, a hairline box, a teal focus
/// ring). With no single definition there was nothing for the stragglers
/// to point at, so this file is that definition; the recipe below is
/// byte-equivalent to `AddTransactionDialog._fieldDecoration`.
///
/// The recipe: `isDense` + `filled` on [ThemeColorsExt.tileSurface] with a
/// [kHouseFieldRadius] `OutlineInputBorder` carrying `BorderSide.none` —
/// the fill, not a stroke, is what draws the field. Two consequences worth
/// knowing before you use it:
///
/// * **Don't nest it on a `tileSurface` background.** A field filled with
///   the same tone as the surface behind it has no visible boundary once
///   the border is gone (the lending dialogs' `_section` cards had exactly
///   that fill and were changed to a hairline outline when they adopted
///   this).
/// * **There is no focus ring**, by design — the floating label recolours
///   to the primary tone on focus, as it does on every other house field.
///
/// Menu chrome lives in `menus.dart`, button sizing in `buttons.dart`;
/// this is the third leg of the same "one definition, all call sites"
/// idea.
library;

import 'package:flutter/material.dart';

import '../utils/theme_colors.dart';

/// Corner radius of a house form field. Exposed so a tappable
/// `InputDecorator` (a date field, say) can give its `InkWell` the same
/// `borderRadius` and keep the splash inside the field's corners.
const double kHouseFieldRadius = 12.0;

/// House [InputDecoration]: filled, rounded, borderless.
///
/// [labelText] is nullable only for the genuinely label-less field (a
/// search box that carries a hint and a leading icon instead) — every
/// data-entry field should pass one, both for accessibility and because
/// the widget tests find fields by their label.
///
/// [prefixIcon] takes an [IconData] rather than a widget so every call
/// site gets the same 18px leading glyph; pass null for no icon.
InputDecoration houseFieldDecoration(
  BuildContext context, {
  String? labelText,
  String? hintText,
  String? prefixText,
  String? suffixText,
  IconData? prefixIcon,
  FloatingLabelBehavior? floatingLabelBehavior,
}) {
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    prefixText: prefixText,
    suffixText: suffixText,
    prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 18),
    floatingLabelBehavior: floatingLabelBehavior,
    isDense: true,
    filled: true,
    fillColor: context.tileSurface,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(kHouseFieldRadius),
      borderSide: BorderSide.none,
    ),
  );
}
