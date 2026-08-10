import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/home_widget_sparkline.dart';

// The widget sparkline's ACTUAL output bytes, decoded and inspected.
//
// This test exists because the first sparkline shipped blank: it went through
// HomeWidget.renderFlutterWidget, whose internal Column gave the paint an
// unbounded height — debug builds assert, RELEASE builds strip the assert and
// emit an empty image. Every layout-level check passed while the owner's
// phone showed fresh numbers over an empty white strip. The only assertion
// that catches that class of failure is on the pixels themselves.

/// Decoded RGBA pixels of the rendered PNG.
Future<ByteData> _pixels(List<int> png) async {
  final codec = await ui.instantiateImageCodec(
    Uint8List.fromList(png),
    // Match the render size so pixel coordinates line up 1:1.
  );
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!;
}

/// Count of pixels that are visibly the sparkline green (any alpha > ~50%).
int _greenPixels(ByteData rgba) {
  var count = 0;
  for (var i = 0; i < rgba.lengthInBytes; i += 4) {
    final r = rgba.getUint8(i);
    final g = rgba.getUint8(i + 1);
    final b = rgba.getUint8(i + 2);
    final a = rgba.getUint8(i + 3);
    if (a > 128 && g > 100 && g > r && g > b) count++;
  }
  return count;
}

void main() {
  test('the rendered PNG actually contains a visible line', () async {
    final png = await renderSparklinePng([
      for (var i = 0; i < 30; i++) 1500000.0 + i * 1000,
    ]);
    expect(png, isNotNull);
    final rgba = await _pixels(png!);
    // A 600x140 bitmap with a 4px diagonal stroke paints thousands of green
    // pixels; a blank render paints zero. The threshold is deliberately far
    // from both so neither AA nor thinning can flake it.
    expect(
      _greenPixels(rgba),
      greaterThan(1000),
      reason: 'a blank bitmap is exactly the bug this test pins',
    );
  });

  test('a flat month still draws its midline', () async {
    final png = await renderSparklinePng([
      for (var i = 0; i < 10; i++) 500000.0,
    ]);
    final rgba = await _pixels(png!);
    expect(_greenPixels(rgba), greaterThan(1000));
  });

  test(
    'an unplottable series renders nothing rather than an empty file',
    () async {
      // The io bridge clears chart_path on null, and the provider hides the
      // image — an empty PNG would instead decode fine and show as blank strip.
      expect(await renderSparklinePng([1000.0]), isNull);
      expect(await renderSparklinePng([]), isNull);
    },
  );

  test(
    'the background stays transparent for the native card to show through',
    () async {
      final png = await renderSparklinePng([
        for (var i = 0; i < 30; i++) 1500000.0 + i * 1000,
      ]);
      final rgba = await _pixels(png!);
      // Top-left corner is above the line and outside the fill — it must be
      // fully transparent, or the bitmap carries its own background and stops
      // matching the card behind it in one of the two themes.
      expect(rgba.getUint8(3), 0);
    },
  );
}
