# General Rust conventions

Industry best practices for writing Rust, distilled from the [Fuchsia Rust
Rubric](https://fuchsia.dev/fuchsia-src/development/api/rust), the [Rust API
Guidelines](https://rust-lang.github.io/api-guidelines/checklist.html) (checklist
codes `C-XXX`), the [Rust Style Guide](https://doc.rust-lang.org/style-guide/),
and the [Clippy lint index](https://rust-lang.github.io/rust-clippy/master/index.html).

This complements — does not replace — the project-specific rules in
[SKILL.md](SKILL.md). Where a rule below has a project-specific instance, it's
cross-referenced (e.g. the "don't swallow errors" rule is SKILL.md §6).

**Calibration:** patrimonio is an axum/sqlx **application binary**, not a
published library. Rules tagged **[app]** are high-value here; **[lib]** ones
matter mainly if you extract a shared crate — apply them there, skip them for
internal handler code. The error-handling/panic and type-safety rules are the
ones to actually enforce.

## 1. Error handling & panics [app]

- **Propagate with `?` / `Result`; don't `.unwrap()` / `.expect()` in
  production paths.** Reserve them for tests, `main`, and provably-infallible
  cases — and there prefer `.expect("why this cannot fail")` over `.unwrap()`
  so the invariant is documented. This matches SKILL.md §1 (handlers return
  `Result<_, ApiError>`, 500s go through `internal()`).
  *Lint:* `clippy::unwrap_used`, `clippy::expect_used` (allow in tests).
- **No `panic!` / `unreachable!` / `todo!` / `unimplemented!` on reachable
  paths.** Validate arguments and return an error instead (Fuchsia `C-VALIDATE`).
  *Lint:* `clippy::panic`, `clippy::unreachable`, `clippy::todo`.
- **Don't index/slice runtime data with `[i]` — use `.get(i)` and handle
  `None`.** `[i]` is a hidden panic path. *Lint:* `clippy::indexing_slicing`.
- **Don't hide errors behind `.unwrap_or(default)` / `.ok()`.** A default is
  fine when absence is genuinely valid, but never to paper over a failure you
  should surface — this is SKILL.md §6 (best-effort reads OK; semantically
  meaningful emptiness is not).
- **Make errors meaningful:** implement `Error` + `Display`, carry context,
  don't stringly-type (`C-GOOD-ERR`). The project split is `thiserror`-style
  typed domain errors (currently: the hand-written `ApiError`) at the boundary,
  `anyhow` in services.
- **`Drop` must never panic** (`C-DTOR-FAIL`) — a panic while unwinding aborts.

## 2. Types & safety [app]

- **Newtypes over primitive obsession.** Wrap `UserId(Uuid)`, `Cents(i64)` so
  the compiler stops you mixing semantically different values (`C-NEWTYPE`).
  Especially relevant to money/ids in this codebase.
- **Prefer enums over `bool`/flag parameters.** `f(Overwrite::Yes)` beats
  `f(true)` at the call site (`C-CUSTOM-TYPE`). *Lint:*
  `clippy::fn_params_excessive_bools`.
- **Exhaustive `match`; avoid catch-all `_` on your own enums** so a new variant
  is a compile error, not a silent fallthrough. *Lint:*
  `clippy::wildcard_enum_match_arm`.
- **Avoid `as` numeric casts — use `TryFrom` / `try_into()` (fallible) or
  `From` (lossless).** `as` is silently lossy. *Lint:* `clippy::as_conversions`,
  `clippy::cast_possible_truncation`. (Note: the codebase's `Decimal → f64` for
  chart display goes via string-parse, not `as`; keep it that way.)
- **Handle integer overflow deliberately** with `checked_*` / `saturating_*` /
  `wrapping_*` — release builds wrap silently. *Lint:*
  `clippy::arithmetic_side_effects`.
- **Use `NonZero*` / `Option<NonZero>` niches** to encode "can't be zero" in the
  type.
- **Avoid `unsafe`; if unavoidable, every `unsafe` block gets a `// SAFETY:`
  comment** explaining why each precondition holds. *Lint:*
  `clippy::undocumented_unsafe_blocks`. `#![forbid(unsafe_code)]` where feasible.

## 3. API design [lib — apply if you extract a crate]

- **Accept borrowed types:** `&str` over `&String`, `&[T]` over `&Vec<T>`,
  `impl AsRef<Path>` over `&PathBuf` (`C-CALLER-CONTROL`). **[app-applicable]**
- **Provide `From` / `TryFrom`** for conversions rather than ad-hoc
  constructors; implement `Display` to get `ToString` free (`C-CONV-TRAITS`).
- **`#[must_use]`** on guards/builders/pure computations whose result must not
  be dropped.
- **Builder pattern** for values with many optional fields (`C-BUILDER`).
- **Derive common traits eagerly:** `Debug` on all public types (`C-DEBUG`),
  plus `Clone`/`Copy`/`PartialEq`/`Eq`/`Hash`/`Default` where sensible; only
  smart pointers implement `Deref` (`C-DEREF`).
- **Keep struct fields private; don't leak internal types** across a public API
  (`C-STRUCT-PRIVATE`). Use **sealed traits** to prevent downstream impls
  (`C-SEALED`).

## 4. Concurrency / async hygiene [app — high value for axum]

- **Never hold a lock guard (`Mutex`/`RwLock`/`RefCell`) across `.await`** —
  deadlock (and, for `RefCell`, a runtime panic) risk. Scope the guard in a
  block that ends before the await, or use an async-aware lock. *Lint:*
  `clippy::await_holding_lock`, `clippy::await_holding_refcell_ref` (on by
  default — **suspicious** group).
- **Don't run blocking/CPU-bound work on the async runtime** — offload to
  `tokio::task::spawn_blocking` so you don't stall the executor.

## 5. Naming & style [app]

- **Standard casing** (RFC 430): `UpperCamelCase` types/traits/variants,
  `snake_case` fns/vars/modules, `SCREAMING_SNAKE_CASE` consts (`C-CASE`).
- **Getters omit `get_`:** `fn name(&self) -> &str`, not `get_name()`
  (`C-GETTER`).
- **Iterator methods are `iter` / `iter_mut` / `into_iter`;** conversions use
  `as_` / `to_` / `into_` reflecting cost & ownership (`C-ITER`, `C-CONV`).
- **Format with `rustfmt` defaults and don't fight it** (4-space, 100-col,
  trailing commas). Run `cargo fmt --check` + `cargo clippy` in CI.

## 6. Documentation [app for clarity; C-EXAMPLE lib-only]

- **`///`-doc public items**, and document a fn's **Errors**, **Panics**, and
  **Safety** sections when it can error, panic, or is `unsafe` (`C-FAILURE`).
  *Lint:* `clippy::missing_errors_doc`, `clippy::missing_panics_doc`,
  `clippy::missing_safety_doc`. This dovetails with SKILL.md §7 (the project's
  "why-not-what" comment density).

## Suggested clippy starter set for this app

Cherry-pick (do **not** blanket-enable the whole `restriction` group — Clippy's
own `blanket_clippy_restriction_lints` warns against it):

```
unwrap_used, expect_used, panic, unreachable, todo, indexing_slicing,
as_conversions, cast_possible_truncation, arithmetic_side_effects,
undocumented_unsafe_blocks, await_holding_lock, await_holding_refcell_ref,
missing_errors_doc, missing_panics_doc
```

with `clippy.toml`:
```toml
allow-unwrap-in-tests = true
allow-expect-in-tests = true
allow-panic-in-tests = true
```

Turn on `pedantic` broadly and cherry-pick from `restriction`. `correctness`
(deny) and `suspicious`/`style`/`complexity`/`perf` (warn) are already on by
default.

## Sources

- Fuchsia Rust Rubric — https://fuchsia.dev/fuchsia-src/development/api/rust
- Fuchsia API Documentation Readability Rubric — https://fuchsia.dev/fuchsia-src/development/api/documentation
- Rust API Guidelines checklist — https://rust-lang.github.io/api-guidelines/checklist.html
- Rust Style Guide — https://doc.rust-lang.org/style-guide/
- Clippy lint index — https://rust-lang.github.io/rust-clippy/master/index.html
- Clippy lint configuration — https://doc.rust-lang.org/clippy/lint_configuration.html
