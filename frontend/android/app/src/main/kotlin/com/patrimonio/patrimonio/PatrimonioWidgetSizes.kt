package com.patrimonio.patrimonio

/**
 * Size variants of the home-screen widget.
 *
 * Android has no notion of "one widget, several offered sizes" — the picker
 * lists one entry per PROVIDER, so each offered size is a receiver. This is a
 * subclass rather than a copy: all rendering, toggle handling and layout
 * selection live in [PatrimonioWidgetProvider], and the variant contributes
 * only a different `targetCell*` default in its own `appwidget-provider` XML.
 *
 * **Two sizes on purpose.** A 4x2 "large" variant existed briefly and was
 * dropped: the picker gives every row the height of the TALLEST widget an app
 * offers, so one 2-row entry padded every other entry with dead space. The
 * roomy two-line layout is still reachable — drag any widget past ~90dp and
 * [PatrimonioWidgetProvider.layoutFor] switches to it — it just isn't offered
 * as its own picker entry.
 *
 * Referenced ONLY from AndroidManifest.xml, so R8 keeps it via the manifest;
 * no explicit keep rule needed (verified in the release DEX).
 */
class PatrimonioWidgetProviderSmall : PatrimonioWidgetProvider()
