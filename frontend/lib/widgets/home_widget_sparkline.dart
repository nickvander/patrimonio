import 'package:flutter/material.dart';

import '../utils/sparkline_geometry.dart';

/// The sparkline bitmap rendered INTO the Android home-screen widget.
///
/// This widget is never mounted in the app's tree: `renderFlutterWidget`
/// paints it in an off-screen pipeline and hands the PNG's path to the
/// Kotlin provider, which just `setImageViewBitmap`s it. Consequences:
///
/// * **No `context` colors.** There is no Theme above an off-screen render,
///   and the PNG is one file serving both the light and dark widget cards —
///   so the color is a fixed mid-green chosen to read on `#FFFFFF` and
///   `#12161C` alike (the two `widget_background` values). Passing
///   `context.positive` here would also bake the app's CURRENT theme into a
///   bitmap that outlives theme switches.
/// * **Transparent background.** The card behind it is the native drawable,
///   which is what swaps on dark mode; the bitmap must not carry its own.
class HomeWidgetSparkline extends StatelessWidget {
  final List<double> values;

  const HomeWidgetSparkline({super.key, required this.values});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _SparklinePainter(values), size: Size.infinite);
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;

  _SparklinePainter(this.values);

  /// Reads on both widget backgrounds; see the class doc for why it is fixed.
  static const Color _line = Color(0xFF16A05B);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = sparklinePoints(values, width: size.width, height: size.height);
    if (pts.isEmpty) return;

    final path = Path()..moveTo(pts.first.x, pts.first.y);
    for (final p in pts.skip(1)) {
      path.lineTo(p.x, p.y);
    }

    // Soft fill under the line first, so the stroke sits on top. The fill
    // fades to transparent — against either card color — rather than to a
    // hardcoded surface.
    final fill = Path.from(path)
      ..lineTo(pts.last.x, size.height)
      ..lineTo(pts.first.x, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_line.withValues(alpha: 0.22), _line.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = _line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.values != values;
}
