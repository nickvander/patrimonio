import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/mask_aware_name.dart';

/// Secondary line under a holding's ticker — "fund name · institution ·
/// account" — truncating the LEAST identifying segment first.
///
/// The old pre-joined single Text ellipsized end-first, which on phone
/// widths always cut the ACCOUNT — the only part that disambiguates the
/// same fund held in two accounts ("Oracle Corporation · Fidelity NetBen…").
/// Here each segment is its own Text so truncation follows identification
/// value instead of word order:
///
///   1. the fund legal name is the flexible segment — it ellipsizes first;
///   2. the institution ellipsizes second, once the name is fully spent;
///   3. the account is laid out at natural width and only ellipsizes when
///      it ALONE exceeds the row — and a trailing "••1234" mask stays
///      visible even then, via [maskAwareNameText] (same seam as the
///      accounts panel).
///
/// A segment squeezed below a few legible characters is dropped together
/// with its " · " separator rather than rendering orphan "…" noise. The
/// semantics node always carries the full untruncated string, so screen
/// readers (and the web semantics tree) are unaffected by visual clipping.
class HoldingSubtitle extends StatelessWidget {
  final String name;
  final String institution;
  final String account;
  final TextStyle style;

  const HoldingSubtitle({
    super.key,
    required this.name,
    required this.institution,
    required this.account,
    required this.style,
  });

  static const String _sep = ' · ';

  @override
  Widget build(BuildContext context) {
    final parts = [name, institution, account].where((s) => s.isNotEmpty);
    if (parts.isEmpty) return const SizedBox.shrink();
    final full = parts.join(_sep);
    return Semantics(
      label: full,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          if (!maxW.isFinite) {
            // Unbounded width (shouldn't happen in the table/mobile rows):
            // fall back to the legacy single-string rendering.
            return Text(
              full,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          }
          // Text merges its style with the ambient DefaultTextStyle and the
          // MediaQuery text scale — the measuring painter must do the same
          // or the caps would be computed for a different font.
          final effective = DefaultTextStyle.of(context).style.merge(style);
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          double measure(String s) {
            final painter = TextPainter(
              text: TextSpan(text: s, style: effective),
              textDirection: direction,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            // Ceil so a segment capped at its own natural width never
            // ellipsizes from sub-pixel rounding.
            final w = painter.width.ceilToDouble();
            painter.dispose();
            return w;
          }

          final sepW = measure(_sep);
          // Below this a segment would show only "…"-noise — drop it.
          final minSeg = measure('MM…');

          // Assign widths in protection order: account > institution >
          // name. Each kept segment also reserves the separator toward the
          // segment after it, so the inflexible children can never sum past
          // maxW (which would paint an overflow instead of ellipsizing).
          var showName = name.isNotEmpty;
          var showInst = institution.isNotEmpty;
          final showAcct = account.isNotEmpty;
          var budget = maxW;
          var acctCap = 0.0;
          var instCap = 0.0;
          if (showAcct) {
            acctCap = math.min(measure(account), budget);
            budget -= acctCap;
          }
          if (showInst) {
            final avail = budget - (showAcct ? sepW : 0.0);
            if (avail >= minSeg || !showAcct) {
              instCap = math.min(measure(institution), math.max(0.0, avail));
              budget = avail - instCap;
            } else {
              showInst = false;
            }
          }
          if (showName && (showInst || showAcct)) {
            // The name is Flexible (it simply absorbs whatever is left);
            // only decide whether that leftover is worth rendering at all.
            if (budget - sepW < minSeg) showName = false;
          }

          Text segment(String text) => Text(
            text,
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );
          Text separator() => Text(_sep, style: style, maxLines: 1);

          final children = <Widget>[];
          if (showName) {
            children.add(Flexible(child: segment(name)));
          }
          if (showInst) {
            if (children.isNotEmpty) children.add(separator());
            children.add(
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: instCap),
                child: segment(institution),
              ),
            );
          }
          if (showAcct) {
            if (children.isNotEmpty) children.add(separator());
            children.add(
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: acctCap),
                child: maskAwareNameText(account, style),
              ),
            );
          }
          return Row(children: children);
        },
      ),
    );
  }
}
