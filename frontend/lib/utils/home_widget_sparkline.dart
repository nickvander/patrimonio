import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'sparkline_geometry.dart';

/// Renders the home-screen widget's net-worth sparkline straight to PNG
/// bytes with a [ui.PictureRecorder].
///
/// **Why not `HomeWidget.renderFlutterWidget`.** That pipeline wraps the
/// given widget in a `Column`, whose children get an UNBOUNDED main axis —
/// a paint-the-whole-cell sparkline therefore lays out at infinite height.
/// Debug builds assert on that; RELEASE builds strip the assert and quietly
/// produce a blank image, which is exactly how this shipped: fresh numbers
/// over an empty white chart strip on the owner's phone, while the debug-side
/// probe looked perfect. Recording the canvas directly involves no layout at
/// all, so there is no constraint system to disagree with — and it is the
/// literal code path the visual probe verified.
///
/// **Theme-blind on purpose.** One PNG serves both widget cards, so the line
/// is a fixed mid-green that reads on `#FFFFFF` and `#12161C` alike (the two
/// `widget_background` values), and the fill fades to transparent rather
/// than to either surface. A theme-aware color would also bake the app's
/// CURRENT theme into a bitmap that outlives theme switches.
const Color _line = Color(0xFF16A05B);

/// The net-worth line's green, public so the io bridge names one constant
/// instead of re-inlining the hex.
const Color sparklineNetWorthColor = _line;

/// The rate sparkline's blue — the app's "info / lake blue" family
/// (theme/palette.dart), split the difference between its light and dark
/// values so one PNG reads on both cards. Exists so the FX chart can NEVER be
/// mistaken for the net-worth chart: both lived in the same slot in the same
/// green, and the owner's first question was "is that exchange rate or net
/// worth?" — a chart you have to ask about is worse than no chart.
const Color sparklineFxColor = Color(0xFF3F8FC4);

Future<Uint8List?> renderSparklinePng(
  List<double> values, {
  double width = 600,
  double height = 140,
  Color line = _line,
}) async {
  final pts = sparklinePoints(values, width: width, height: height);
  if (pts.isEmpty) return null;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width, height);

  final path = Path()..moveTo(pts.first.x, pts.first.y);
  for (final p in pts.skip(1)) {
    path.lineTo(p.x, p.y);
  }

  // Soft fill under the line first, so the stroke sits on top.
  final fill = Path.from(path)
    ..lineTo(pts.last.x, height)
    ..lineTo(pts.first.x, height)
    ..close();
  canvas.drawPath(
    fill,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [line.withValues(alpha: 0.22), line.withValues(alpha: 0)],
      ).createShader(Offset.zero & size),
  );

  canvas.drawPath(
    path,
    Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  final image = await recorder.endRecording().toImage(
    width.round(),
    height.round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}
