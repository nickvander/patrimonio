import 'package:flutter/material.dart';

/// Animated grey block used as a placeholder while real data loads. The
/// pulse is a low-amplitude opacity animation rather than the classic
/// shimmer because shimmer can look jittery on slow connections and the
/// dashboard already has plenty of motion (charts, etc.) — keep it calm.
class SkeletonBox extends StatefulWidget {
  final double? width;
  final double height;
  final BorderRadius borderRadius;
  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        final t = 0.04 + (_ctrl.value * 0.08);
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: t),
            borderRadius: widget.borderRadius,
          ),
        );
      },
    );
  }
}

/// Layout-true skeleton for the Overview tab. Mirrors the KPI strip +
/// cash-flow card + side-by-side body layout so the page doesn't reflow
/// once data lands.
class OverviewSkeleton extends StatelessWidget {
  const OverviewSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final isNarrow = c.maxWidth < 900;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: List.generate(
                5,
                (_) => SizedBox(
                  width: isNarrow ? c.maxWidth : (c.maxWidth - 4 * 12) / 5,
                  child: const SkeletonBox(height: 88),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const SkeletonBox(height: 140),
            const SizedBox(height: 24),
            if (isNarrow) ...const [
              SkeletonBox(height: 260),
              SizedBox(height: 24),
              SkeletonBox(height: 440),
            ] else
              const Row(
                children: [
                  Expanded(flex: 1, child: SkeletonBox(height: 600)),
                  SizedBox(width: 24),
                  Expanded(flex: 3, child: SkeletonBox(height: 600)),
                ],
              ),
          ],
        ),
      );
    });
  }
}
