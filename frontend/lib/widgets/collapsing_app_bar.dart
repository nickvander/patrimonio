import 'package:flutter/material.dart';

/// Scroll-away shell for the compact app bar (enter-always + snap semantics).
///
/// Keeps `Scaffold.appBar` instead of migrating tabs to slivers:
/// [preferredSize] stays constant — Scaffold only uses it as a *max*
/// constraint and positions the body by the bar's ACTUAL laid-out height
/// (`_ScaffoldLayout.performLayout` uses `layoutChild(...).height`) — so
/// animating the inner height slides the body up/down smoothly, with the
/// wrapped [AppBar] itself completely untouched. Its default lift-on-scroll
/// surface tint keeps working: the scrolled-under listener registers with the
/// Scaffold's own ScrollNotificationObserver, which wraps this slot too.
///
/// Collapsed, the shell never reaches height 0 on a phone: an opaque strip of
/// exactly the status-bar inset remains (painted in the bar's own background
/// colour), so tab content never renders under the OS status bar.
class CollapsingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const CollapsingAppBar({
    super.key,
    required this.visible,
    required this.child,
  });

  /// Whether the bar is shown. Flipping this triggers the ~200ms snap.
  final bool visible;

  /// The untouched app bar being slid in/out.
  final AppBar child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final expanded = child.preferredSize.height + topInset;
    // Implicitly animated — no controller to own or dispose. t runs 1.0
    // (shown) -> 0.0 (collapsed to the status-bar strip); the short easeInOut
    // is the "snap". The bar subtree is passed as `child` so it is NOT
    // rebuilt per animation frame — only this cheap shell is.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: visible ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: child,
      builder: (context, t, bar) {
        return SizedBox(
          height: topInset + (expanded - topInset) * t,
          child: ClipRect(
            child: Stack(
              children: [
                // Bottom-anchored at its full height inside the shrinking
                // clip, so the bar slides up out of view rather than
                // squashing its contents. While hidden it must not be
                // hit-testable through the residual strip.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: expanded,
                  child: IgnorePointer(ignoring: !visible, child: bar!),
                ),
                // Opaque status-bar strip: fades in as the bar leaves so no
                // toolbar content ever sits under the OS status bar, and at
                // rest fully covers the slice of the bar still inside the
                // clip. Uses the bar's themed background (falling back to
                // surface) so the strip blends with it in both themes.
                if (t < 1.0)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: topInset,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: 1.0 - t,
                        child: ColoredBox(
                          color:
                              Theme.of(context).appBarTheme.backgroundColor ??
                              Theme.of(context).colorScheme.surface,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
