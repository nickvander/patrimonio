import 'package:flutter/material.dart';

/// Horizontal scroller for the too-narrow-for-the-table case: an
/// always-visible 6px scrollbar thumb under the table plus a 16px alpha
/// fade on whichever edge still has clipped content, so a 1024×768 user
/// sees "there's more" instead of a silently cut-off Gain/Return column.
/// Owns its ScrollController (the Scrollbar and the scroll view must share
/// one that isn't the page's PrimaryScrollController).
class EdgeFadedHScroll extends StatefulWidget {
  final Widget child;

  const EdgeFadedHScroll({super.key, required this.child});

  @override
  State<EdgeFadedHScroll> createState() => _EdgeFadedHScrollState();
}

class _EdgeFadedHScrollState extends State<EdgeFadedHScroll> {
  final ScrollController _controller = ScrollController();
  // Content starts scrolled to the leading edge, so before the first
  // metrics arrive only the trailing side fades — this widget is only
  // built when the table is wider than the viewport.
  bool _atStart = true;
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_controller.hasClients) _apply(_controller.position);
  }

  void _apply(ScrollMetrics m) {
    final atStart = m.pixels <= 1.0;
    final atEnd = m.pixels >= m.maxScrollExtent - 1.0;
    if (atStart == _atStart && atEnd == _atEnd) return;
    // Metrics notifications can arrive during layout, where setState is
    // illegal — defer to the frame's end (one frame of fade lag, invisible).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _atStart = atStart;
        _atEnd = atEnd;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    const opaque = Color(0xFFFFFFFF);
    const transparent = Color(0x00FFFFFF);
    return NotificationListener<ScrollMetricsNotification>(
      // Fires on layout-driven metric changes (resize, rows expanding)
      // that never tick the controller listener.
      onNotification: (n) {
        _apply(n.metrics);
        return false;
      },
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        thickness: 6,
        child: ShaderMask(
          // dstIn: the child keeps only the alpha of this gradient — a
          // 16px fade-out on the side(s) with more content, theme-agnostic
          // because it never paints a color of its own.
          shaderCallback: (rect) {
            final fade = rect.width <= 0
                ? 0.0
                : (16.0 / rect.width).clamp(0.0, 0.45);
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                _atStart ? opaque : transparent,
                opaque,
                opaque,
                _atEnd ? opaque : transparent,
              ],
              stops: [0.0, fade, 1.0 - fade, 1.0],
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            // Bottom lane for the always-visible thumb so it doesn't sit
            // on the last row's figures.
            padding: const EdgeInsets.only(bottom: 10),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
