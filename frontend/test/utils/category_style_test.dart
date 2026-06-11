import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/theme/palette.dart';
import 'package:patrimonio/utils/category_style.dart';

// categoryStyleFor is a pure function (label + brightness in, style out) so
// these tests never pump a widget — no BuildContext, no ApiService, no
// package:web. The registry is keyed on prettyCategory output, so the
// fixtures below use real labels from utils/category.dart's en/es maps.
void main() {
  test('deterministic: repeated calls return the identical (icon, color)',
      () {
    for (final label in ['Comida y bebida', 'Travel', 'Tanda con primos']) {
      for (final b in Brightness.values) {
        final a1 = categoryStyleFor(label, b);
        final a2 = categoryStyleFor(label, b);
        expect(a1.icon, a2.icon, reason: '$label/$b icon must be stable');
        expect(a1.color, a2.color, reason: '$label/$b color must be stable');
      }
    }
  });

  test('known Spanish import category gets its explicit mapping', () {
    // "Supermercado" is prettyCategory's es label for
    // FOOD_AND_DRINK_GROCERIES — the food family: cart icon, terracotta.
    final dark = categoryStyleFor('Supermercado', Brightness.dark);
    expect(dark.icon, Icons.shopping_cart_outlined);
    expect(dark.color, BrandPalette.terracotta(Brightness.dark));

    // "Comisiones bancarias" (BANK_FEES) — fees family, and crucially NOT
    // the old grey fallback that every Spanish label used to land on.
    final fees = categoryStyleFor('Comisiones bancarias', Brightness.light);
    expect(fees.icon, Icons.receipt_long_outlined);
    expect(fees.color, isNot(Colors.grey));
    expect(fees.color, isNot(BrandPalette.neutral(Brightness.light)));
  });

  test('English and Spanish labels for the same bucket share one style', () {
    final en = categoryStyleFor('Food & drink', Brightness.dark);
    final es = categoryStyleFor('Comida y bebida', Brightness.dark);
    expect(en.icon, es.icon);
    expect(en.color, es.color);
  });

  test('lookup is case-insensitive (labels are data, not enums)', () {
    final a = categoryStyleFor('TRANSFERENCIA RECIBIDA', Brightness.dark);
    final b = categoryStyleFor('Transferencia recibida', Brightness.dark);
    expect(a.icon, b.icon);
    expect(a.color, b.color);
  });

  test('unknown categories: stable, brand-palette, never grey', () {
    // Free-typed labels a user might actually enter — none in the registry.
    const unknowns = [
      'Tanda con primos',
      'Colegiatura',
      'Veterinario',
      'Cooperacha oficina',
      'Kombucha casera',
      'Clases de salsa',
    ];
    for (final b in Brightness.values) {
      final palette = categoryFallbackPalette(b);
      final colors = <Color>[];
      for (final label in unknowns) {
        final style = categoryStyleFor(label, b);
        // Stable across calls.
        expect(style.color, categoryStyleFor(label, b).color);
        // Drawn from the curated brand list, not grey/neutral.
        expect(palette, contains(style.color));
        expect(style.color, isNot(Colors.grey));
        expect(style.color, isNot(BrandPalette.neutral(b)));
        colors.add(style.color);
      }
      // Different unknowns spread across the palette (hash, not constant).
      expect(colors.toSet().length, greaterThan(1));
    }
  });

  test('light/dark variance is the documented hue-family shift', () {
    // Identity is the hue FAMILY: the icon never changes with brightness,
    // and the color is that family's brightness-matched BrandPalette shade
    // (neon-leaning in dark, darker AA-passing in light) — not a random
    // re-roll per brightness.
    final dark = categoryStyleFor('Transporte', Brightness.dark);
    final light = categoryStyleFor('Transporte', Brightness.light);
    expect(dark.icon, light.icon);
    expect(dark.color, BrandPalette.info(Brightness.dark));
    expect(light.color, BrandPalette.info(Brightness.light));
    expect(dark.color, isNot(light.color));
  });

  test('uncategorized buckets are deliberately neutral', () {
    for (final label in ['Uncategorized', 'Sin categoría', null, '  ']) {
      final style = categoryStyleFor(label, Brightness.dark);
      expect(style.color, BrandPalette.neutral(Brightness.dark),
          reason: '"$label" means "no signal" and should read neutral');
    }
  });
}
