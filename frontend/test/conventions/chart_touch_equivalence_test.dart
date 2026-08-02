import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural guard for the chart-touch byte-equivalence contract
// (skills/flutter-frontend/SKILL.md §5). `standardLineTouch` in
// lib/utils/chart_touch.dart is the canonical app-standard line-chart hover
// (snap-to-nearest-X, guide + halo dot, tooltipSurface popover, 12px
// corners). The three headline charts — net-worth card, projections screen,
// instrument sheet — predate the helper and deliberately keep their own
// inline `LineTouchData` copies, under the contract that those copies stay
// equivalent to the helper. Until now nothing enforced that: the projections
// tooltip had silently drifted to fl_chart's default 4px corner radius.
//
// This test extracts the shared interaction sub-regions from each site and
// compares them, whitespace-normalized, against the canonical helper:
//
//   1. the snap block  — `touchSpotThreshold: 100000` + the dx-only
//      `distanceCalculator`;
//   2. the touched-spot indicator — the guide `FlLine` and the ring
//      `FlDotCirclePainter`;
//   3. the tooltip chrome — `getTooltipColor: … => context.tooltipSurface`
//      and `tooltipRoundedRadius: 12`.
//
// Deliberately OUTSIDE the compared contract (per-site wiring, not shared
// feel): `handleBuiltInTouches` / `touchCallback` (the projections screen
// owns its tooltip state; the other copies are wrapped in
// TransientTooltipLineChart), the helper-only `fitInsideHorizontally/
// Vertically` (added for edge-flush charts; the headline charts sit in
// padded cards), the helper's parametric `showIndicator` no-op branch, and
// each chart's `getTooltipItems` content.
//
// If this test fails after you edited a chart: re-sync the region with
// `standardLineTouch` (lib/utils/chart_touch.dart) — or, if the divergence
// is a conscious design decision, record it in [_frozenVariances] below with
// a reason. Don't fork a new inline copy either way: new charts must call
// `standardLineTouch` (the second test pins that).

/// Deliberate, frozen per-site divergences from the canonical text.
/// Key: lib-relative path → fact name → expected normalized text.
/// Do not add entries to silence a failure you can't explain — every entry
/// here documents a divergence that was investigated and judged intentional.
const Map<String, Map<String, String>> _frozenVariances = {
  // Theme sweep f3dfd97 routed the guide line through `context.tint(0.35)`,
  // which boosts alpha ~1.6x in LIGHT mode for visual parity (identical to
  // the canonical raw 0.35 in dark mode). The sweep did not touch
  // net_worth_card, and the later helper mirrored net_worth_card — so both
  // spellings coexist deliberately. Dark-equivalent, light slightly bolder.
  'lib/screens/wealth_projection_screen.dart': {
    'guideLine': 'FlLine(color: context.tint(0.35), strokeWidth: 1)',
  },
  'lib/widgets/instrument_detail_sheet.dart': {
    // Same tint(0.35) spelling as the projections screen (see above).
    'guideLine': 'FlLine(color: context.tint(0.35), strokeWidth: 1)',
    // Born this way (0aa7dc9): the instrument sheet's compact chart uses a
    // smaller ring dot (4/2.5 vs 5/3), and `color` is the sheet's single
    // series color — behaviorally the same resolution as the canonical
    // `barData.color ?? context.positive` for a one-series chart.
    'dot':
        'FlDotCirclePainter(radius: 4, color: color, strokeWidth: 2.5, '
        'strokeColor: Theme.of(context).colorScheme.surface)',
  },
};

/// The canonical helper + the three sanctioned inline copies.
const String _canonicalPath = 'lib/utils/chart_touch.dart';
const List<String> _copyPaths = [
  'lib/widgets/net_worth_card.dart',
  'lib/screens/wealth_projection_screen.dart',
  'lib/widgets/instrument_detail_sheet.dart',
];

/// Files allowed to construct an inline `LineTouchData(` at all.
/// account_balance_chart.dart predates the helper with a plain (non-snap)
/// tooltip — frozen as legacy; migrating it to `standardLineTouch` shrinks
/// this list. Everything else must use the helper.
const Set<String> _inlineLineTouchDataFiles = {
  _canonicalPath,
  ..._copyPaths,
  'lib/widgets/account_balance_chart.dart',
};

void main() {
  group('chart-touch equivalence (SKILL.md §5)', () {
    test('inline headline-chart copies match canonical standardLineTouch', () {
      final root = _packageRoot();
      final canonical = _extractFacts(
        _canonicalPath,
        _readLib(root, _canonicalPath),
      );

      final failures = <String>[];
      for (final path in _copyPaths) {
        final facts = _extractFacts(path, _readLib(root, path));
        final variances = _frozenVariances[path] ?? const {};
        for (final name in canonical.keys) {
          final expected = variances[name] ?? canonical[name]!;
          final actual = facts[name];
          if (actual != expected) {
            final frozen = variances.containsKey(name);
            failures.add(
              '$path: "$name" diverges from '
              '${frozen ? 'its frozen variance entry' : 'the canonical helper'}'
              ' (lib/utils/chart_touch.dart standardLineTouch).\n'
              '  expected: $expected\n'
              '  actual:   $actual\n'
              '  Re-sync the inline copy with the helper, or — only for a '
              'conscious design decision — update _frozenVariances in this '
              'test with a documented reason.',
            );
          }
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n\n'));
      // Sanity: the canonical extraction produced all four facts — if the
      // helper is refactored so the anchors move, fix the extractor rather
      // than trusting a vacuous pass.
      expect(canonical.keys, containsAll(_factNames));
    });

    test('no new inline LineTouchData forks outside the sanctioned set', () {
      final root = _packageRoot();
      final offenders = <String>[];
      for (final file in _libDartFiles(root)) {
        final rel = _relPath(root, file);
        final code = _stripFullLineComments(file.readAsStringSync());
        final inline = RegExp(r'(?<!\w)LineTouchData\(').hasMatch(code);
        if (inline && !_inlineLineTouchDataFiles.contains(rel)) {
          offenders.add(
            '$rel: constructs an inline LineTouchData. New line charts must '
            'use standardLineTouch(context, items: …) from '
            'lib/utils/chart_touch.dart (SKILL.md §5) — do not fork another '
            'copy of the hover recipe.',
          );
        }
        // A forked copy of the SNAP recipe specifically (even without the
        // full LineTouchData shape) is the drift §5 exists to prevent.
        if (code.contains('touchSpotThreshold') &&
            !{_canonicalPath, ..._copyPaths}.contains(rel)) {
          offenders.add(
            '$rel: sets touchSpotThreshold outside the sanctioned '
            'headline-chart copies — use standardLineTouch instead.',
          );
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}

const List<String> _factNames = [
  'snapBlock',
  'guideLine',
  'dot',
  'tooltipChrome',
];

/// Extracts the four compared facts from [rawCode] (comments stripped here).
/// Fails loudly (with [path]) if an anchor is missing, so a refactor updates
/// this test consciously instead of passing vacuously.
Map<String, String> _extractFacts(String path, String rawCode) {
  final code = _stripFullLineComments(rawCode);

  String failMissing(String what) {
    fail(
      '$path: could not locate $what — if the chart was refactored, update '
      'the site table / extractor in '
      'test/conventions/chart_touch_equivalence_test.dart to follow it.',
    );
  }

  // 1. Snap block: touchSpotThreshold + the dx-only distanceCalculator.
  final snap = RegExp(
    r'touchSpotThreshold[\s\S]{0,240}?\.abs\(\),',
  ).firstMatch(code);
  if (snap == null) failMissing('the snap block (touchSpotThreshold)');

  // 2. Indicator block: getTouchedSpotIndicator up to its `}).toList();`.
  final indStart = code.indexOf('getTouchedSpotIndicator');
  if (indStart < 0) failMissing('getTouchedSpotIndicator');
  final indEnd = code.indexOf('}).toList();', indStart);
  if (indEnd < 0) failMissing('the end of the indicator block');
  final indicator = code.substring(indStart, indEnd);

  // Guide line: the visible FlLine (the helper's showIndicator:false branch
  // paints a transparent no-op FlLine — parametric, not part of the shared
  // recipe — so it is skipped).
  const noOpGuide = 'FlLine(color: Colors.transparent, strokeWidth: 0)';
  final guides = _balancedCalls(
    indicator,
    'FlLine',
  ).map(_normalize).where((g) => g != noOpGuide).toList();
  if (guides.length != 1) {
    failMissing(
      'exactly one visible guide FlLine in the indicator block '
      '(found ${guides.length})',
    );
  }

  final dots = _balancedCalls(indicator, 'FlDotCirclePainter');
  if (dots.length != 1) failMissing('exactly one FlDotCirclePainter');

  // 3. Tooltip chrome: between LineTouchTooltipData( and getTooltipItems.
  final chromeStart = code.indexOf('LineTouchTooltipData(');
  if (chromeStart < 0) failMissing('LineTouchTooltipData');
  final chromeEnd = code.indexOf('getTooltipItems', chromeStart);
  if (chromeEnd < 0) failMissing('getTooltipItems');
  final chrome = code.substring(chromeStart, chromeEnd);
  final surface = RegExp(
    r'getTooltipColor:\s*\(\s*\w+\s*\)\s*=>\s*context\.tooltipSurface',
  ).hasMatch(chrome);
  final radius = RegExp(
    r'tooltipRoundedRadius:\s*(\d+)',
  ).firstMatch(chrome)?.group(1);

  return {
    'snapBlock': _normalize(snap!.group(0)!),
    'guideLine': guides.single,
    'dot': _normalize(dots.single),
    // Reduced to the two shared chrome facts so per-chart args between them
    // (comments, fitInside on the helper) don't produce noise.
    'tooltipChrome':
        'surface=${surface ? 'context.tooltipSurface' : 'NON-STANDARD'} '
        'radius=${radius ?? 'fl_chart default (4) — set 12'}',
  };
}

/// Every balanced `name(...)` call expression found in [code], raw text
/// including the name. The compared regions contain no string literals with
/// unbalanced parens, so a plain depth counter is sufficient.
List<String> _balancedCalls(String code, String name) {
  final calls = <String>[];
  var from = 0;
  while (true) {
    final start = code.indexOf('$name(', from);
    if (start < 0) break;
    var depth = 0;
    var i = start + name.length;
    while (i < code.length) {
      final c = code[i];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    calls.add(code.substring(start, i + 1));
    from = i + 1;
  }
  return calls;
}

/// Collapses formatting so `dart format` line-wrapping differences (and
/// trailing commas it introduces) don't defeat the byte comparison.
String _normalize(String code) => code
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('( ', '(')
    .replaceAll(' )', ')')
    .replaceAll(',)', ')')
    .trim();

/// Drops whole-line `//` / `///` comments (the files under test mention the
/// anchors in prose); trailing comments are left alone — the anchors never
/// appear in one.
String _stripFullLineComments(String code) =>
    code.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

String _readLib(Directory root, String relPath) {
  final f = File('${root.path}/$relPath');
  if (!f.existsSync()) {
    fail(
      '$relPath not found under ${root.path} — if the file moved, update the '
      'site table in test/conventions/chart_touch_equivalence_test.dart.',
    );
  }
  return f.readAsStringSync();
}

Iterable<File> _libDartFiles(Directory root) => Directory('${root.path}/lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _relPath(Directory root, File file) {
  final prefix = '${root.path}/';
  return file.path.startsWith(prefix)
      ? file.path.substring(prefix.length)
      : file.path;
}

/// The package root, tolerant of the test being run with CWD at either the
/// package root (`flutter test`) or inside `test/`.
Directory _packageRoot() {
  for (final path in ['.', '..']) {
    if (File('$path/pubspec.yaml').existsSync() &&
        Directory('$path/lib').existsSync()) {
      return Directory(path);
    }
  }
  fail('package root not found from ${Directory.current.path}');
}
