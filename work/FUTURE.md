# Future work backlog

> **Purpose:** Plans that aren't urgent enough for [NEXT.md](NEXT.md) and aren't tied to a numbered phase, but are worth keeping in writing so they don't drop out of memory.

---

## prefer_const_literals_to_create_immutables sweep

**Status:** Deferred, not blocking.
**Tracking:** This file.
**Owner:** Whoever next runs `dart fix` on the frontend.

### Background

The May 2026 light-theme sweep (`afded3a`) stripped `const` wholesale from `Text(...)` / `TextStyle(...)` / `Icon(...)` / `Divider(...)` expressions because the inside of those expressions now reads from `BuildContext` via `ThemeColorsExt` (`context.textPrimary`, etc.). `dart fix --apply --code=prefer_const_constructors` (`b784f3e`) reapplied `const` on the 185 call sites whose constructors stayed eligible, and `prefer_const_constructors` is now enabled permanently in `frontend/analysis_options.yaml` so the regression can't quietly accumulate again.

The companion lint `prefer_const_literals_to_create_immutables` covers the *children* lists of those constructors — `children: [SizedBox(...), Text(...), ...]` becoming `children: const [SizedBox(...), Text(...), ...]` when every element is itself const. This one is **off** because it has a higher false-positive rate than its sibling: a `const` list is immutable, so if downstream code later wants to mutate the children list (rare but real, especially in stateful widgets that compose conditional children), the const literal forces a refactor.

### Why we deferred it

`dart fix --apply --code=prefer_const_literals_to_create_immutables` would currently produce ~80-120 changes (rough estimate, run `dart fix --dry-run` to verify when the time comes). Each one needs eyes on it because:

- **Mutation hazard.** Some lists look immutable today but are spread into a `Column` that conditionally adds rows via `if (...)` or `...spread` syntax. If a `const` list ever needs to gain an element at build time, the cast becomes a runtime crash.
- **Hot reload edge cases.** Const literals get tree-shaken; replacing one with a runtime list can cause a hot-reload restart in some setups.
- **The benefit is small.** `const` on the children list saves one extra heap allocation per build. For Patrimonio at current scale (a few dozen rows per tab) that's invisible.

### Plan when picked up

1. Run a dry-run first to see the scope:
   ```bash
   cd frontend && dart fix --dry-run --code=prefer_const_literals_to_create_immutables
   ```
2. Apply only one file at a time, not the bulk-apply. For each change, eyeball the surrounding state class: if there's any `setState` that could conditionally add to the list, skip that one with `// ignore: prefer_const_literals_to_create_immutables` and a one-line rationale comment.
3. Run `flutter analyze` after each file to catch any regressions early.
4. Spot-check the affected widgets in both light and dark mode in the browser — most issues will surface as "this widget refuses to render" rather than as analyzer errors.
5. Once stable, opt the lint into `analysis_options.yaml` alongside `prefer_const_constructors` so future drift gets caught.

### When to do this

- Not before the next major UI feature lands (less churn = easier review).
- Maybe pair it with a "performance pass" once the app has more users and frame timings start to matter — at which point all the small allocation wins compound.
- A natural trigger: if a future widget refactor already has the file open and analyze flags ten of these in the same file, just apply them in the same commit.

### Rollback

`git revert` the single commit; the changes are mechanical and self-contained per call site. No data or schema impact.
