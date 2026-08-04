import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural guard for the form-panel presentation rule
// (skills/flutter-frontend/SKILL.md §4 "Form panels present sheet-on-narrow,
// dialog-on-wide"): each panel widget takes an `asSheet` flag and renders the
// sheet or the AlertDialog shell off it, and exactly ONE entry point — the
// `open…Panel(context, …)` helper that lives beside the widget — decides
// which. A host that calls `showDialog(builder: (_) => AddFooDialog(...))`
// itself silently opts out: the app then shows a cramped dialog at phone
// width, and the sheet shell (thumb-reachable, primary action pinned above
// the soft keyboard) never renders. That is exactly what happened to
// `openAddRecurringRulePanel`, which shipped complete and tested with its
// only host still on a raw `showDialog` — the split existed and was dead.
//
// The check is source-level on purpose: the defect is "the helper is not
// called", which no isolated widget test can see (each panel's two branches
// are already asserted through the helper in
// test/widgets/dialog_house_idiom_test.dart).
//
// If this test fails: replace the direct construction with the matching
// `open…Panel(context, …)` helper, passing the same arguments.

/// Panel widget → the lib-relative file that owns it AND its opener. The
/// widget may only be constructed there (the opener builds it for both
/// branches); every other host goes through the opener.
const Map<String, String> _panelOwners = {
  'AddTransactionDialog': 'lib/widgets/add_transaction_dialog.dart',
  'AddRecurringRuleDialog': 'lib/widgets/add_recurring_rule_dialog.dart',
};

void main() {
  test('lib/: form panels are opened through their open…Panel helper', () {
    final root = _packageRoot();
    final failures = <String>[];

    for (final entry in _panelOwners.entries) {
      final widget = entry.key;
      final owner = entry.value;
      // A constructor invocation: the class name followed by `(`. Prose
      // references (`[AddTransactionDialog]`, `AddTransactionDialog.
      // _dialogShell`) don't match, and comment lines are skipped anyway.
      final ctor = RegExp('\\b$widget\\s*\\(');
      // The opener must exist and be the documented entry point.
      final ownerFile = File('${root.path}/$owner');
      if (!ownerFile.existsSync()) {
        failures.add('$owner: owner file for $widget not found');
        continue;
      }

      for (final file in _libDartFiles(root)) {
        final rel = _relPath(root, file);
        if (rel == owner) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (line.trimLeft().startsWith('///')) continue;
          if (!ctor.hasMatch(line)) continue;
          failures.add(
            '$rel:${i + 1}: ${line.trim()}\n'
            '  $widget is constructed outside $owner. Route this host through '
            'the open…Panel helper beside the widget so it presents as a '
            'bottom sheet on narrow layouts and a dialog on wide.',
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
