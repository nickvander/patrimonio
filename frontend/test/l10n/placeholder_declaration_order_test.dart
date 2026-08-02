import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural guard for the OTHER half of the gen-l10n ordering trap
// (skills/flutter-frontend/SKILL.md §2). Keys WITHOUT placeholder metadata
// get ALPHABETICAL parameters (pinned per-key in placeholder_order_test.dart);
// keys WITH a `placeholders` block get parameters in the metadata's
// DECLARATION order. Dozens of call sites pass args in template/reading
// order and are correct only because every declaration order happens to
// match its template order today — nothing else pins that.
//
// This test makes the invariant structural: for every key in app_en.arb that
// declares placeholder metadata, the declaration order must equal the order
// the placeholders first appear in the template string. A new key (or a
// reorder of an existing block) that breaks it fails here with the exact
// key, instead of silently transposing same-typed args at every call site.
//
// If a key ever legitimately needs a declaration order that differs from
// its template, don't weaken this test — reorder the metadata to match the
// template and adjust the call sites; reading order is the house contract.

/// Legacy exceptions, frozen: these keys were declared before the
/// template-order contract, mostly in ALPHABETICAL order (matching the
/// metadata-less convention), and their call sites — each carrying a
/// "gen-l10n orders these …" comment — pass args in that declared order
/// today. Reordering their metadata would change the generated signatures
/// and silently transpose every call site's same-typed args, so they stay
/// as-is; the test instead pins their EXACT declared order, so any edit to
/// one of these blocks still fails loudly and forces a conscious decision.
/// Do not add new keys here — declare new metadata in template order.
const Map<String, List<String>> _frozenLegacyOrders = {
  'txSpikeBanner': [
    'average',
    'category',
    'monthLabel',
    'months',
    'percent',
    'recent',
  ],
  'txClaimNetWorthMove': ['amount', 'date', 'percent'],
  'txClaimReconciliation': ['amount', 'count'],
  'impStaleBannerSummary': ['days', 'name'],
  'lwTrendsSemanticSummary': ['count', 'income', 'month', 'spending'],
  'lwAllocSemanticLabel': ['category', 'pct', 'count'],
  'fxcChartSemantics': ['count', 'latest', 'pair'],
};

void main() {
  test('app_en.arb: placeholder metadata declares in template order', () {
    final arbFile = _locateArb();
    final arb = jsonDecode(arbFile.readAsStringSync()) as Map<String, dynamic>;

    final failures = <String>[];
    var checkedKeys = 0;

    for (final entry in arb.entries) {
      if (!entry.key.startsWith('@') || entry.key.startsWith('@@')) {
        continue;
      }
      final key = entry.key.substring(1);
      final meta = entry.value;
      if (meta is! Map<String, dynamic>) continue;
      final placeholders = meta['placeholders'];
      if (placeholders is! Map<String, dynamic> || placeholders.isEmpty) {
        continue;
      }
      final template = arb[key];
      if (template is! String) {
        failures.add('$key: has placeholder metadata but no template');
        continue;
      }

      checkedKeys++;

      final frozen = _frozenLegacyOrders[key];
      if (frozen != null) {
        // Legacy key: its declared order IS the (comment-annotated)
        // call-site contract — pin it byte-for-byte instead of requiring
        // template order.
        expect(
          placeholders.keys.toList(),
          frozen,
          reason:
              '$key: frozen legacy placeholder order changed — every call '
              'site passes args in the old declared order, so this edit '
              'silently transposes them. Revert, or update ALL call sites '
              'and move the key out of _frozenLegacyOrders (declaring in '
              'template order).',
        );
        continue;
      }

      var lastIndex = -1;
      var lastName = '';
      for (final name in placeholders.keys) {
        final index = _firstUse(template, name);
        if (index < 0) {
          failures.add(
            '$key: declares placeholder "$name" that the template '
            'never uses',
          );
          continue;
        }
        if (index < lastIndex) {
          failures.add(
            '$key: metadata declares "$lastName" before "$name" but the '
            'template uses "$name" first — the generated signature '
            'follows DECLARATION order, so call sites written in '
            'template order would transpose. Reorder the placeholders '
            'block to match the template.',
          );
        }
        lastIndex = index;
        lastName = name;
      }
    }

    expect(failures, isEmpty, reason: failures.join('\n'));
    // Sanity: the arb genuinely contains metadata'd keys — if this drops
    // to zero the test is scanning the wrong file, not proving safety.
    expect(checkedKeys, greaterThan(0));
  });
}

/// First index where [name] is used as a placeholder in [template] — either
/// plain `{name}` or as an ICU argument head `{name, plural, ...}`.
int _firstUse(String template, String name) {
  final match = RegExp(
    '\\{\\s*${RegExp.escape(name)}\\s*[,}]',
  ).firstMatch(template);
  return match?.start ?? -1;
}

/// The template arb, tolerant of the test being run with CWD at either the
/// package root (`flutter test`) or inside `test/`.
File _locateArb() {
  for (final path in ['lib/l10n/app_en.arb', '../lib/l10n/app_en.arb']) {
    final f = File(path);
    if (f.existsSync()) return f;
  }
  fail('lib/l10n/app_en.arb not found from ${Directory.current.path}');
}
