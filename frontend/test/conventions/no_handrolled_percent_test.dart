import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural guard for the percent-formatting rule
// (skills/flutter-frontend/SKILL.md §2 "never hand-roll"): a hand-built
// `'$v%'` renders wrong in es-MX, which wants a comma decimal and an NBSP
// before the sign — exactly the bug class utils/percent_format.dart exists
// to prevent (formatPercent / formatPercentLocale / localizePercentString /
// localizeNumberString). Recent sweeps routed the offenders through those
// helpers; this test keeps new ones from creeping back in.
//
// It scans lib/ for string literals that glue an interpolation directly to a
// `%` sign (`…${x.toStringAsFixed(1)}%…`, `…${x.round()}%…`, `…$pct%…`) or
// concatenate one (`+ '%'`). Excluded by design:
//   - lib/utils/            — percent_format.dart IS the sanctioned place;
//   - lib/l10n/             — generated from the arb files, where `{rate}%`
//                             belongs to the translator (the es file owns its
//                             own typography);
//   - full-line comments    — prose like `// a fake green "+0.00%"`;
//   - bare `'%'` literals   — e.g. `suffixText: '%'` on a TextField, a lone
//                             symbol affordance, not a composed number.
//
// If this test fails: use the percent_format.dart helper that fits
// (formatPercent for fixed digits, localizePercentString for variable
// precision) — or, only for a genuinely legitimate exception, extend
// [_frozenExceptions] with the file, the exact expected hit count, and a
// reason.

/// Frozen exceptions: lib-relative path → (hits, reason). The count must
/// match reality EXACTLY — fixing an offender means shrinking the entry, and
/// a new offender in an already-listed file still fails. Keep this list as
/// small as possible.
const Map<String, ({int hits, String reason})> _frozenExceptions = {};

/// A `%` glued directly onto an interpolation inside a string literal —
/// `…}%` (block interpolation) or `…$name%` (simple interpolation) followed
/// by the literal's closing quote or more text; plus `+ '%'` concatenation.
final List<RegExp> _patterns = [
  RegExp(r'\}%'),
  RegExp(r'\$[a-zA-Z_][a-zA-Z0-9_]*%'),
  RegExp(r'''\+\s*['"]%['"]'''),
];

void main() {
  test('lib/: no hand-rolled percent strings outside utils/', () {
    final root = _packageRoot();
    final hitsByFile = <String, List<String>>{};

    for (final file in _libDartFiles(root)) {
      final rel = _relPath(root, file);
      if (rel.startsWith('lib/utils/') || rel.startsWith('lib/l10n/')) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (_patterns.any((p) => p.hasMatch(line))) {
          (hitsByFile[rel] ??= []).add('$rel:${i + 1}: ${line.trim()}');
        }
      }
    }

    final failures = <String>[];
    for (final entry in hitsByFile.entries) {
      final allowed = _frozenExceptions[entry.key];
      if (allowed == null) {
        failures.add(
          '${entry.value.join('\n')}\n'
          '  Hand-rolled percent string — es-MX needs a comma decimal and an '
          'NBSP before "%". Use utils/percent_format.dart '
          '(formatPercent / localizePercentString / localizeNumberString) '
          'instead, or — only for a genuine exception — add a frozen '
          '_frozenExceptions entry with a reason.',
        );
      } else if (entry.value.length != allowed.hits) {
        failures.add(
          '${entry.key}: expected exactly ${allowed.hits} frozen hand-rolled '
          'percent hit(s), found ${entry.value.length}:\n'
          '${entry.value.join('\n')}\n'
          '  Fix new offenders via utils/percent_format.dart; if you removed '
          'a frozen one, shrink its _frozenExceptions entry.',
        );
      }
    }
    // A frozen entry whose file no longer hits at all is stale — prune it.
    for (final path in _frozenExceptions.keys) {
      if (!hitsByFile.containsKey(path)) {
        failures.add(
          '$path: listed in _frozenExceptions but no longer contains a '
          'hand-rolled percent string — delete the stale entry.',
        );
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
