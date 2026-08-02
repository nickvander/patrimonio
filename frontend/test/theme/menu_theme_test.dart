import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/theme/menus.dart';
import 'package:patrimonio/theme/palette.dart';

/// Smoke test for the house menu chrome (theme/menus.dart): a stock
/// [PopupMenuButton] opened under the app's popupMenuTheme must render on
/// the brand card surface with the 12px house radius — the exact regression
/// behind the "stock greenish transactions kebab" screenshot. The theme is
/// assembled with the same public builders `main.dart` wires in, so a drift
/// in the builders fails here without pumping the real app.
void main() {
  ThemeData appLikeTheme(Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: BrandPalette.seed(b),
      brightness: b,
      surface: BrandPalette.cardSurface(b),
      secondary: BrandPalette.terracotta(b),
      tertiary: BrandPalette.gold(b),
    );
    final textTheme = ThemeData(brightness: b).textTheme;
    return ThemeData(
      brightness: b,
      colorScheme: scheme,
      useMaterial3: true,
      popupMenuTheme: buildPopupMenuTheme(b, scheme, textTheme),
      menuTheme: buildMenuTheme(b),
    );
  }

  Future<void> pumpAndOpenMenu(WidgetTester tester, Brightness b) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLikeTheme(b),
        home: Scaffold(
          body: PopupMenuButton<int>(
            itemBuilder: (_) => const [
              PopupMenuItem(value: 1, child: Text('Alpha')),
              PopupMenuItem(value: 2, child: Text('Beta')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
  }

  for (final b in Brightness.values) {
    testWidgets('popup menu renders house surface + 12px radius ($b)', (
      tester,
    ) async {
      await pumpAndOpenMenu(tester, b);

      // Nearest Material above a menu item is the menu surface itself.
      final menuMaterial = tester.widget<Material>(
        find
            .ancestor(of: find.text('Alpha'), matching: find.byType(Material))
            .first,
      );
      expect(menuMaterial.color, BrandPalette.cardSurface(b));
      expect(
        menuMaterial.shape,
        const RoundedRectangleBorder(borderRadius: kMenuRadius),
      );
      // Elevation tint killed so the card surface shows verbatim.
      expect(menuMaterial.surfaceTintColor, Colors.transparent);

      // Long-label readability: items inherit the house body style with the
      // 1.35 line height (what keeps wrapped labels like the cross-currency
      // scan entry legible).
      final itemStyle = tester
          .widget<AnimatedDefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Alpha'),
                  matching: find.byType(AnimatedDefaultTextStyle),
                )
                .first,
          )
          .style;
      expect(itemStyle.height, 1.35);
    });

    testWidgets('dropdown helper matches the popup surface ($b)', (
      tester,
    ) async {
      await pumpAndOpenMenu(tester, b);
      final context = tester.element(find.byType(Scaffold));
      // The legacy dropdown route has no theme hook; its per-site helper
      // must resolve to the same surface the popup theme uses.
      expect(houseDropdownColor(context), BrandPalette.cardSurface(b));
    });
  }
}
