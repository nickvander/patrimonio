package com.patrimonio.patrimonio

/**
 * Size variants of the home-screen widget.
 *
 * Android has no notion of "one widget, several offered sizes" — the picker
 * lists one entry per PROVIDER. Offering small/default/large therefore means
 * three receivers, which is why these are subclasses rather than three copies:
 * all rendering, toggle handling and layout selection live in
 * [PatrimonioWidgetProvider], and each variant contributes only a different
 * `targetCell*` default in its own `appwidget-provider` XML.
 *
 * Every variant is resizable to every other variant's size — they differ only
 * in where they start.
 *
 * These classes are referenced ONLY from AndroidManifest.xml, so R8 keeps them
 * via the manifest; no explicit keep rule is needed (verified in the release
 * DEX).
 */
class PatrimonioWidgetProviderSmall : PatrimonioWidgetProvider()

class PatrimonioWidgetProviderLarge : PatrimonioWidgetProvider()
