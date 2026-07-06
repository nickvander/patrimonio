import 'package:flutter/material.dart';

/// Renders [name] on one line, splitting a trailing "••1234"-style mask
/// into its own non-shrinking token so a long base name ellipsizes in the
/// middle ("Ultimate Rew… ••1234") instead of truncating the only part
/// that tells same-named cards apart (the sync appends the card mask when
/// an issuer reuses one marketing name across accounts). Falls back to a
/// plain ellipsizing Text when the name has no mask suffix.
Widget maskAwareNameText(String name, TextStyle style) {
  final m = RegExp(r'^(.*\S)\s+(••\S{1,6})$').firstMatch(name);
  if (m == null) {
    return Text(
      name,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(
          m.group(1)!,
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      Text(' ${m.group(2)!}', style: style, maxLines: 1),
    ],
  );
}
