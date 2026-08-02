/// Sizing rules for the app's "action" buttons — the standalone calls to
/// action that sit inside a Settings card (Add accounts, Sync all accounts),
/// as opposed to inline row/table affordances.
///
/// WHY THIS EXISTS: these buttons were laid out with a mobile rule that had no
/// upper bound —
///
/// ```dart
/// final tileWidth = isNarrow ? c.maxWidth : (c.maxWidth - 16) / 2;   // old
/// SizedBox(width: double.infinity, child: ElevatedButton.icon(...))  // old
/// ```
///
/// — so a desktop window stretched "Import statement" to 565px and "Sync all
/// accounts" to the full 1650px card width. Full-bleed is the correct pattern
/// on a phone (thumb reach, one action per row) and it is what makes the
/// mobile layout read well; carried to a 1440px window it turns a button into
/// a banner, flattens the visual hierarchy, and makes the whole page look
/// unfinished. The rest of the app already does the right thing — Lending's
/// "Add loan", the Data-export row, Tax's "Export CSV" are all content-sized
/// — so this is an inconsistency, not the house style.
///
/// The rule: **touch-width layouts stay full-bleed; pointer-width layouts size
/// to the label**, bounded by [kActionButtonMaxWidth] so one long es-MX string
/// can't reintroduce the stretch.
library;

import 'package:flutter/material.dart';

/// Compact-layout / phone-width threshold: below this inner width a layout
/// takes its narrow form (header rows stack, segment labels swap to their
/// short variants, side-by-side columns fold to one). Derivation: four
/// equal-flex period segments need ~136px each for the longest es-MX full
/// label, ≈550px with gaps, rounded up (see `CashFlowPeriodSelector`).
const double kCompactLayoutBelow = 560;

/// Card inner width below which a card is treated as touch-shaped and its
/// action buttons go full-bleed and stacked.
///
/// Matches the breakpoint the Add-accounts grid already used, and — per the
/// house convention — is measured against the card's INNER `LayoutBuilder`
/// constraint, never `MediaQuery` screen width: the same card is narrow inside
/// a phone viewport and inside a desktop side panel.
const double kActionButtonStackBelow = 520;

/// Upper bound for a content-sized action button.
///
/// M3 Expressive sizes buttons by height, not width, and leaves width to the
/// label; a cap is still wanted here because these labels are localized and
/// "Conectar cuentas estándar"-length strings would otherwise stretch a row
/// back toward the old banner look.
const double kActionButtonMaxWidth = 320;

/// Lower bound, so a row of two- and three-word labels lays out as a tidy set
/// rather than a ragged one.
const double kActionButtonMinWidth = 180;

/// Height for a standard action button.
///
/// M3 Expressive's button size ramp is XSmall 32 / Small 40 / Medium 56 /
/// Large 96. These buttons were on Medium (`vertical: 18` → 56dp), which that
/// spec reserves for a screen's single hero action. For the utility actions in
/// a Settings card, Small is the right step, and it matches the ~40dp the
/// content-sized buttons elsewhere in the app already land on.
const double kActionButtonHeight = 40;

/// Width to give an action button inside a card whose inner width is
/// [available], or `null` to let the button size to its own content.
double? actionButtonWidth(double available) =>
    available < kActionButtonStackBelow ? available : null;

/// Constraints for a content-sized action button, so a wrapped row stays tidy
/// without any button stretching to fill.
BoxConstraints actionButtonConstraints(double available) =>
    available < kActionButtonStackBelow
    ? BoxConstraints.tightFor(width: available)
    : const BoxConstraints(
        minWidth: kActionButtonMinWidth,
        maxWidth: kActionButtonMaxWidth,
      );
