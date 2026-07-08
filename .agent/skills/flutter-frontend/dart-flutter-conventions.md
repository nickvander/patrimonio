# General Dart & Flutter conventions

Industry best practices distilled from [Effective Dart](https://dart.dev/effective-dart)
(Style / Usage / Design / Documentation), the [Flutter repo style
guide](https://github.com/flutter/flutter/blob/master/docs/contributing/Style-guide-for-Flutter-repo.md),
[Flutter performance best practices](https://docs.flutter.dev/perf/best-practices),
and the [Dart linter rules](https://dart.dev/tools/linter-rules).

This complements — does not replace — the project-specific rules in
[SKILL.md](SKILL.md); cross-references to those sections are noted inline.

Rules marked **[lint: `name`]** are enforceable by a named linter rule.
**✓flutter_lints** = already active in this project (`analysis_options.yaml`
includes `package:flutter_lints/flutter.yaml` and additionally enables
`prefer_const_constructors`). Where a rule is not yet enabled, it's a candidate
to add.

## Widgets & build

- **Prefer `const` constructors** for widgets and subtrees so Flutter skips
  rebuilding and reuses instances. **[lint: `prefer_const_constructors` (enabled),
  `prefer_const_constructors_in_immutables` ✓flutter_lints]**
- **Keep `build()` cheap, pure, and idempotent** — no side effects, no async, no
  I/O or expensive computation; that work belongs in `initState`, constructors,
  or memoized fields. (The project already extracts logic to `utils/` — SKILL.md
  §1. Keep doing that.)
- **Factor large widgets into smaller Widget CLASSES, not helper methods that
  return `Widget`.** Subclasses get their own build context, can be `const`, and
  rebuild independently; helper methods rebuild with the whole parent. This is
  the concrete fix for the god-files anti-pattern in SKILL.md §"Anti-patterns".
- **Localize rebuilds:** `setState()` on the smallest subtree that changes; push
  state down; pass unchanging subtrees as `child:` to `AnimatedBuilder` /
  `ListenableBuilder` instead of rebuilding them.
- **Give widget constructors a `Key`** (`super.key`). **[lint:
  `use_key_in_widget_constructors` ✓flutter_lints]**
- **Lazy builders for long/off-screen lists** (`ListView.builder`), not a
  concrete `List<Widget>` where most children aren't visible.
- **`SizedBox` for whitespace, not `Container`;** drop decoration-less single-
  child `Container`s. **[lint: `sized_box_for_whitespace`,
  `avoid_unnecessary_containers` ✓flutter_lints]**
- **`child`/`children` last** in the argument list. **[lint:
  `sort_child_properties_last` ✓flutter_lints]**
- **No logic in `createState()`; don't override `operator==` on widgets.**
  **[lint: `no_logic_in_create_state` ✓flutter_lints]**
- **Minimize expensive rendering ops** — prefer `AnimatedOpacity`/`FadeInImage`
  over `Opacity`, avoid needless clipping / `saveLayer()`.

## Lifecycle & resources

- **Always `dispose()` what you own:** `AnimationController`,
  `TextEditingController`, `ScrollController`, `FocusNode`, `ChangeNotifier`,
  etc. in `State.dispose()`. (The project uses module-level `ValueNotifier`s that
  live for the app lifetime — those are fine; the rule bites for per-widget
  controllers.)
- **Cancel `StreamSubscription`s and close sinks** you create. **[lint:
  `cancel_subscriptions`, `close_sinks` — candidates to add]** Directly relevant
  to the `RealtimeService` broadcast stream subscribers (SKILL.md §1).
- **Guard `setState()` and any post-`await` use of `State` with `if (mounted)`.**

## State & async

- **No real work in constructors** (no I/O/async/side effects) — use
  `initState`/lifecycle or on-demand.
- **Never use a `BuildContext` across an `await` gap without re-checking
  `mounted`.** **[lint: `use_build_context_synchronously` ✓flutter_lints]**
- **Model async UI as explicit loading / data / error states;** handle and
  surface errors, don't assume success. Pairs with SKILL.md §3 (surface backend
  errors via `_errorFromBody`).
- **Prefer `async`/`await` over raw `Future` chains,** but don't mark a function
  `async` if it adds nothing.
- **Keep the UI isolate unblocked:** move heavy CPU work off the main isolate
  (`compute`/isolates); aim to build in ≤8 ms (≤16 ms/frame for 60 fps).

## Style & naming (Effective Dart)

- **Casing:** `UpperCamelCase` types/extensions; `lowercase_with_underscores`
  files/dirs/packages/import-prefixes; `lowerCamelCase` members/vars/constants.
  **[lint: `camel_case_types`, `file_names`, `non_constant_identifier_names`]**
- **Prefer `final` (or `const`) for locals/private fields** not reassigned;
  **don't init to `null`.** **[lint: `prefer_final_locals`, `prefer_final_fields`,
  `avoid_init_to_null` — candidates to add]**
- **No `print` for logging** — use `dart:developer` `log()` or a logging package.
  **[lint: `avoid_print` ✓flutter_lints]**
- **Collection literals; `.isEmpty`/`.isNotEmpty` (not `.length == 0`);
  `whereType<T>()` for type filtering.** **[lint: `prefer_collection_literals`,
  `prefer_is_empty`, `prefer_iterable_whereType`]** (The clamp-crash fix in
  SKILL.md's trends example already switched to `.isEmpty`.)
- **Null-aware operators (`??`, `?.`, `??=`) and string interpolation** over
  manual null checks / `+` concatenation. **[lint:
  `prefer_interpolation_to_compose_strings`]**
- **Order imports** `dart:` → `package:` → relative, each block alphabetized;
  prefer relative imports within the package; never import another package's
  `src/`. **[lint: `directives_ordering`, `implementation_imports` — candidates]**
- **`rethrow`, not `throw e`, to preserve stack traces;** avoid bare `catch`
  without an `on` clause. **[lint: `use_rethrow_when_possible`,
  `avoid_catches_without_on_clauses`]**
- **Name booleans positively** (`enabled`/`visible`, not `disabled`/`hidden`);
  use named params over positional booleans.

## Nullability & types

- **Rely on sound null safety; avoid the `!` bang operator** — reaching for it
  usually signals a nullable-type/promotion/null-check pattern you should use
  instead.
- **Prefer typed models over `Map<String, dynamic>`; avoid `dynamic`** (use
  `Object?` when you truly mean "any"). This is SKILL.md §3's "add a typed
  `fromJson` for new complex responses" — and the num-coercion crash the trends
  fix caught (`e.value['income']` cast straight to `double`) is exactly what
  stringly-typed maps let through. Coerce defensively:
  `(x as num? ?? 0).toDouble()`.
- **Prefer pattern matching / `is` checks over `as` casts** — `as` throws at
  runtime on mismatch.
- **Override `hashCode` whenever you override `==`;** keep `==` reflexive/
  symmetric/transitive; avoid value equality on mutable classes.

## Documentation

- **`///` doc comments (not `/* */`) on public APIs,** starting with a one-
  sentence summary; reference identifiers in `[brackets]`. **[lint:
  `slash_for_doc_comments`, `comment_references`]**
- **Comment the "why," not the "what."** Noun phrases for properties, "Whether…"
  for booleans, third-person verbs for side-effecting methods.

## Lints: current state & suggested additions

Already active: base `lints` recommended + `flutter_lints` (10 rules:
`avoid_print`, `avoid_unnecessary_containers`, `avoid_web_libraries_in_flutter`,
`no_logic_in_create_state`, `prefer_const_constructors_in_immutables`,
`sized_box_for_whitespace`, `sort_child_properties_last`,
`use_build_context_synchronously`, `use_full_hex_values_for_flutter_colors`,
`use_key_in_widget_constructors`) + `prefer_const_constructors`.

Also enabled (2026-07-08, all had a zero backlog when added):
`cancel_subscriptions` and `close_sinks` — **promoted to `error`** in the
`analyzer.errors:` block so an undisposed stream/sink breaks the build, not just
warns — plus `use_rethrow_when_possible` and `prefer_final_locals`.

Still deferred (large backlogs — add incrementally): `avoid_catches_without_on_clauses`
(~186 sites), `directives_ordering` (~108). `prefer_final_fields` is already in
the recommended base set.

## Sources

- Effective Dart — Style / Usage / Design / Documentation: https://dart.dev/effective-dart
- Dart linter rules: https://dart.dev/tools/linter-rules
- flutter_lints rule set: https://github.com/flutter/packages/blob/main/packages/flutter_lints/lib/flutter.yaml
- Flutter performance best practices: https://docs.flutter.dev/perf/best-practices
- Flutter repo style guide: https://github.com/flutter/flutter/blob/master/docs/contributing/Style-guide-for-Flutter-repo.md
