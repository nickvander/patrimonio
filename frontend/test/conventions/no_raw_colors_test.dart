import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural guard for the color rule (skills/flutter-frontend/SKILL.md §4
// "never hardcode colors"): a raw `Colors.white70` / hex that reads fine in
// dark mode fails WCAG AA on the light theme — the exact bug class the
// `context` extension in lib/utils/theme_colors.dart exists to prevent
// (textPrimary/textMuted/…, hairline, tint(), semantic accents, chartSeries,
// tooltipSurface). This test scans lib/ for `Colors.<token>` usages and
// fails on anything not sanctioned.
//
// Sanctioned by design:
//   - lib/theme/ and lib/utils/theme_colors.dart — where tokens are DEFINED;
//   - lib/l10n/ — generated;
//   - `Colors.transparent` everywhere — alpha 0 has no brightness identity;
//   - comments;
//   - the frozen per-file, per-token allowlist below, each entry carrying a
//     reason and an EXACT usage count (so a new raw color in an already
//     allowlisted file still fails, and removing one forces the entry to
//     shrink).
//
// If this test fails: use the `context` extension (or a ColorScheme role)
// instead. Extend [_frozenAllowlist] only when the color is genuinely
// brightness-invariant by nature (scanner-facing QR modules, black scrims/
// shadows, theme construction) — document why.

/// Frozen allowlist: lib-relative path → `Colors.<token>` → (count, reason).
/// Counts must match reality exactly in both directions.
const Map<String, Map<String, ({int count, String reason})>> _frozenAllowlist =
    {
      'lib/main.dart': {
        'Colors.white': (
          count: 2,
          reason:
              'light ThemeData construction — card/dialog surfaces are '
              'defined here; the palette was tuned against literal white '
              '(see the in-file comment).',
        ),
        'Colors.black26': (
          count: 2,
          reason:
              'light ThemeData shadowColor — Material shadows are black in '
              'both brightnesses.',
        ),
        'Colors.black12': (
          count: 1,
          reason: 'light ThemeData DataTable headingRowColor tint.',
        ),
      },
      'lib/screens/security_screen.dart': {
        'Colors.white': (
          count: 1,
          reason:
              'QR-code quiet zone — scanner-facing, must stay dark-on-light '
              'regardless of app theme.',
        ),
        'Colors.black': (
          count: 1,
          reason: 'QR-code modules — scanner-facing, brightness-invariant.',
        ),
      },
      'lib/screens/account_transactions_screen.dart': {
        'Colors.black': (
          count: 2,
          reason:
              'modal barrierColor scrim (idiomatic: Flutter\'s own default '
              'barrier is black-based) + side-panel BoxShadow (shadows are '
              'black in both brightnesses).',
        ),
      },
      'lib/screens/dashboard_screen.dart': {
        'Colors.black': (
          count: 1,
          reason: 'modal barrierColor scrim (idiomatic black-based barrier).',
        ),
      },
      'lib/widgets/transactions_tab.dart': {
        'Colors.black': (
          count: 2,
          reason:
              'modal barrierColor scrim + side-panel BoxShadow '
              '(black in both brightnesses).',
        ),
      },
      'lib/components/allocation_heatmap.dart': {
        'Colors.black45': (
          count: 1,
          reason: 'tile BoxShadow — shadows are black in both brightnesses.',
        ),
      },
    };

void main() {
  test('lib/: no raw Colors.* outside theme layer and frozen allowlist', () {
    final root = _packageRoot();
    // path → token → list of "file:line: source".
    final hits = <String, Map<String, List<String>>>{};
    final pattern = RegExp(r'(?<!\w)Colors\.(\w+)');

    for (final file in _libDartFiles(root)) {
      final rel = _relPath(root, file);
      if (rel.startsWith('lib/theme/') ||
          rel.startsWith('lib/l10n/') ||
          rel == 'lib/utils/theme_colors.dart') {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        for (final m in pattern.allMatches(line)) {
          final token = 'Colors.${m.group(1)!}';
          if (token == 'Colors.transparent') continue;
          ((hits[rel] ??= {})[token] ??= []).add(
            '$rel:${i + 1}: ${line.trim()}',
          );
        }
      }
    }

    final failures = <String>[];
    for (final fileEntry in hits.entries) {
      final allowed = _frozenAllowlist[fileEntry.key] ?? const {};
      for (final tokenEntry in fileEntry.value.entries) {
        final rule = allowed[tokenEntry.key];
        if (rule == null) {
          failures.add(
            '${tokenEntry.value.join('\n')}\n'
            '  Raw ${tokenEntry.key} — hardcoded colors break light-mode '
            'contrast (SKILL.md §4). Use the `context` extension from '
            'lib/utils/theme_colors.dart (textPrimary/textMuted/tint()/'
            'semantic accents/tooltipSurface/…) or a ColorScheme role. Only '
            'a genuinely brightness-invariant use (QR modules, black scrim/'
            'shadow, theme construction) may be added to _frozenAllowlist, '
            'with a reason.',
          );
        } else if (tokenEntry.value.length != rule.count) {
          failures.add(
            '${fileEntry.key}: expected exactly ${rule.count} allowlisted '
            'use(s) of ${tokenEntry.key}, found ${tokenEntry.value.length}:\n'
            '${tokenEntry.value.join('\n')}\n'
            '  New uses need the `context` extension; if you removed one, '
            'shrink the _frozenAllowlist entry.',
          );
        }
      }
    }
    // Stale allowlist entries (file clean, or token gone) must be pruned so
    // the list keeps mirroring reality.
    for (final fileEntry in _frozenAllowlist.entries) {
      for (final token in fileEntry.value.keys) {
        if (!(hits[fileEntry.key]?.containsKey(token) ?? false)) {
          failures.add(
            '${fileEntry.key}: _frozenAllowlist lists $token but the file no '
            'longer uses it — delete the stale entry.',
          );
        }
      }
    }

    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });
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
