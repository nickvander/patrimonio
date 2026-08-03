# User rules engine + dry-run auto-categorization — implementation design

**Status:** Design for owner review (queue item 5, feature-research brief #2).
Produced 2026-08-03 by the feature-research follow-up design pass; implementation
does NOT start until the owner signs off (see §8 open questions).
**Scope:** Explicit, persisted, user-defined rules (categorize + rename) consulted
on both the statement-import and Plaid-sync write paths, with retroactive
application gated behind a previewed, confirmed dry-run diff.
**Non-negotiable invariant:** No historical category/description ever changes
without an explicit, previewed, confirmed apply. Creating, editing, enabling,
disabling, or deleting a rule mutates **zero** existing `transactions` rows on
its own.

---

## 0. The honest delta over what already ships (the skeptic's challenge, answered)

What exists today, precisely:

| Mechanism | Where | What it does |
|---|---|---|
| Curated engine | `backend/src/services/categorize.rs:32` (`categorize()`, 1,109-line module) | Hardcoded es-MX keyword rules → PFC primary code, written into the base `category` column at parse/confirm time. High-precision-not-high-recall by design (`categorize.rs:19-22`). |
| Learn-from-edits | `backend/src/api/imports.rs:485-505` (map build) and `imports.rs:583-590` (application) | On statement-import confirm, builds a `merchant_key → user_category` map from ALL past manual category edits (most-recent-wins), and stamps `user_category` on **fresh inserts only**. |
| `merchant_key` | `categorize.rs:716-769` | Coarse normalizer: first 3 significant words after a noise-word strip; returns `""` for generic rows. |
| Per-row/bulk manual edits | `backend/src/api/accounts.rs:768-830` (single PATCH), `accounts.rs:1052-1109` (`PATCH /transactions/batch`) | Set `user_category` / `user_description`; every read path prefers them (`api/dashboard/mod.rs:208-209` `EFFECTIVE_CATEGORY_SQL`, `spending.rs:181`, `tax.rs:296`). |
| Cluster rename | `frontend/lib/widgets/transactions_tab.dart:2157-2193` (`_similarTransactionIds`) | One-shot "also apply to N matching" bulk PATCH over rows sharing the exact raw description — **client-side, currently-loaded rows only**. |

What is genuinely NOT covered — this is the feature's entire justification:

1. **The Plaid path.** `services/sync.rs::upsert_plaid_transaction` (`sync.rs:1049-1181`) consults neither the learned map nor anything user-defined. A fix taught on the import path never reaches synced US accounts. (The secondary income-insert path at `sync.rs:1750-1776` likewise.)
2. **Renames.** Learn-from-edits is category-only. `user_description` never propagates automatically; the cluster rename is a one-shot over loaded rows, not a persistent policy, and misses rows outside the loaded window and all future rows.
3. **Retroactivity with a diff.** Nothing today can preview "what would this change across ALL history" server-side; the bulk tools operate on the visible list.
4. **Explicitness and manageability.** The learned map is invisible: it can't be listed, scoped, disabled, or corrected. It's recomputed from *every* `user_category` row with most-recent-wins (`imports.rs:501`), so one mis-edit silently becomes standing policy with no UI to find it.
5. **Matching power.** `merchant_key` takes the 3 leading significant words and returns `""` for generic rows (`categorize.rs:1039`). SPEI descriptors where the distinguishing token (RFC, beneficiary) sits deep in the string defeat it; substring/anchored matchers don't.
6. **Scoping.** No per-account / currency / amount / direction conditions exist anywhere.

Learn-from-edits **stays** (as a lower-precedence fallback); this design slots explicit rules above it and fixes the feedback loop (§2.3).

---

## 1. Rule model & migration

One additive migration, `backend/migrations/2026080401_user_rules.sql`, following the `recurring_rules` precedent (`2026072302_recurring_rules.sql` — user-scoped, `active` flag, access-path index):

```sql
CREATE TABLE IF NOT EXISTS user_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Matcher. Evaluated case-insensitively in Rust (single implementation,
    -- see §3) against description, original_description, merchant_name and
    -- counterparty_name ('merchant_key' matches categorize::merchant_key of
    -- original_description ?? description — same basis as learn-from-edits,
    -- imports.rs:566-568).
    match_type  TEXT NOT NULL CHECK (match_type IN
                    ('merchant_key','contains','starts_with','exact')),
    match_value TEXT NOT NULL CHECK (length(btrim(match_value)) > 0),

    -- Scoping. NULL = unrestricted.
    account_id  UUID REFERENCES accounts(id) ON DELETE CASCADE,
    currency    TEXT,
    direction   TEXT CHECK (direction IN ('inflow','outflow')),
    -- Compared against ABS(amount) in the row's NATIVE currency; positive
    -- magnitudes. Direction is a separate axis, matching categorize.rs's
    -- own sign-awareness (categorize.rs:63).
    amount_min  DECIMAL(15,2) CHECK (amount_min IS NULL OR amount_min >= 0),
    amount_max  DECIMAL(15,2) CHECK (amount_max IS NULL OR amount_max >= 0),
    CHECK (amount_min IS NULL OR amount_max IS NULL OR amount_max >= amount_min),

    -- Actions. At least one. Values live in the SAME value space the
    -- transaction editor writes to user_category / user_description today —
    -- no new taxonomy.
    set_category    TEXT,
    set_description TEXT,
    CHECK (set_category IS NOT NULL OR set_description IS NOT NULL),

    -- Deterministic order: priority ASC, created_at ASC, id ASC.
    priority   INTEGER NOT NULL DEFAULT 0,
    active     BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_rules_user_active
    ON user_rules(user_id, active, priority);

-- Provenance on transactions: WHO set user_category / user_description.
-- This is what makes "manual edits always win" enforceable (§2).
ALTER TABLE transactions
  ADD COLUMN IF NOT EXISTS user_category_source TEXT
      CHECK (user_category_source IN ('manual','rule','learned')),
  ADD COLUMN IF NOT EXISTS user_category_rule_id UUID
      REFERENCES user_rules(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS user_description_source TEXT
      CHECK (user_description_source IN ('manual','rule')),
  ADD COLUMN IF NOT EXISTS user_description_rule_id UUID
      REFERENCES user_rules(id) ON DELETE SET NULL;

-- Legacy rows: everything set before this feature is conservatively manual
-- (historical learned-map writes are indistinguishable; treating them as
-- manual can only UNDER-apply rules, never clobber a human edit).
UPDATE transactions SET user_category_source = 'manual'
    WHERE user_category IS NOT NULL AND user_category <> '' AND user_category_source IS NULL;
UPDATE transactions SET user_description_source = 'manual'
    WHERE user_description IS NOT NULL AND user_description <> '' AND user_description_source IS NULL;
```

**Why regex is OUT (v1).** (a) The cited pain (SPEI strings, "PAGO OXXO" variants, RFC codes) is fully served by `contains`/`starts_with` + `merchant_key`; (b) a catastrophic-backtracking pattern would hang the *sync path*, where rules run per-row — on a self-hosted single-family box the "attacker" is the owner, but a wedged sync is a wedged sync (the rust-backend skill's hung-upstream lesson, `SKILL.md` §2); (c) regex invites SQL-vs-Rust semantic divergence that §3's single-implementation rule exists to kill. Revisit only if a real descriptor defeats the shipped matchers (owner question #2).

**Why the rule result lands in `user_category`/`user_description` (not new columns).** Every effective-value read already prefers these: `EFFECTIVE_CATEGORY_SQL` (`dashboard/mod.rs:208-209`), `spending.rs:181,193,411`, `tax.rs:296`, the frontend display ladder and every widget reading `tx['user_category']`. New `rule_*` columns would mean editing every one of those SQL sites plus the frontend — the exact "hand-synced copies drifting apart" failure mode the rust-backend skill warns about for FX. Provenance columns give us manual-vs-machine distinction at zero read-path cost.

---

## 2. Precedence & interplay

Effective value per field, highest first:

| # | Layer | Storage signature | Notes |
|---|---|---|---|
| 1 | **Manual row edit** | `user_* set`, `*_source='manual'` (or legacy NULL source) | Absolute. No rule path may ever overwrite it — enforced by a SQL predicate at every write site, not by convention. |
| 2 | **User rules** (first active match, priority order) | `user_*` set, `*_source='rule'`, `*_rule_id` set | Beats learned, curated, and Plaid PFC. |
| 3 | **Learn-from-edits** (import path only, existing) | `user_category` set, `user_category_source='learned'` | Unchanged behavior, now stamped `'learned'` at `imports.rs:583-590`. |
| 4 | **Curated `categorize.rs` / Plaid PFC** | base `category` | Untouched by this feature. |
| 5 | Nothing | NULL → "Uncategorized" | |

**Mechanics that make this real:**

- **Manual-protection predicate** (shared const, used verbatim in preview, apply, and both forward paths): a field is protected iff its value is non-empty AND `*_source = 'manual' OR *_source IS NULL`. Rules may freely overwrite `'rule'` and `'learned'` values.
- **Manual edits reclaim rows.** The single PATCH (`accounts.rs:806-830`), the batch PATCH (`accounts.rs:1091-1109`), and the manual-edit-clears path (`accounts.rs:962-978`) each gain `user_category_source='manual', user_category_rule_id=NULL` (resp. description) whenever they write that field. A human touch permanently fences the row off from rules until the human clears it.
- **Conflicting rules: first-match-wins *per action field*.** Rules sorted by `(priority ASC, created_at ASC, id ASC)`. The first matching rule with a `set_category` decides category; the first matching rule with a `set_description` decides description — a rename-only rule doesn't shadow a categorize rule below it. New rules append at the end (`priority = max+10`); the reorder endpoint rewrites priorities. The dry-run makes shadowing visible ("0 changes" → drag it up).
- **Rules > learned, and the feedback loop is cut.** The learned-map source query (`imports.rs:487-489`) gains `AND user_category_source = 'manual'` (equivalently: excludes `'rule'`/`'learned'`), so implicit learning derives only from genuine human edits. Without this, rule-written values would re-enter the learned map and a deleted rule would keep resurrecting itself through it.
- **Rule deletion:** applied values persist; `*_rule_id` goes NULL via `ON DELETE SET NULL` but `*_source` stays `'rule'`, so the residue remains machine-owned and a future rule can overwrite it. Deleting a rule never silently rewrites history (that would violate the invariant); a dry-runnable "revert this rule's applications" is full-scope, not MVP (§7).

---

## 3. Application paths — write time, one matcher implementation

**Write time, not read time.** Three reasons, in order of weight:

1. **The invariant demands it.** A read-time rule changes historical aggregates the instant it's saved — exactly the silent-rewrite the brief forbids. Write-time + explicit apply makes the confirmed diff *be* the write.
2. **The read surface is enormous and SQL-side.** `EFFECTIVE_CATEGORY_SQL`, spending aggregations, tax logic, CSV exports, and dozens of frontend readers all consume stored columns. Read-time rules would have to be re-implemented in every one — a factory for the drift bug class.
3. Exports/tax/UI must agree byte-for-byte with what the user confirmed.

**One matcher, in Rust.** New `backend/src/services/rules.rs`:

```rust
pub struct UserRule { /* mirrors table */ }
pub struct RuleInput<'a> {
    pub description: &'a str,
    pub original_description: Option<&'a str>,
    pub merchant_name: Option<&'a str>,
    pub counterparty_name: Option<&'a str>,
    pub amount: Decimal, pub currency: &'a str, pub account_id: Uuid,
}
pub struct RuleOutcome {
    pub category: Option<(String, Uuid)>,     // (value, rule id)
    pub description: Option<(String, Uuid)>,
}
pub fn apply_rules(rules: &[UserRule], input: &RuleInput) -> RuleOutcome;
pub fn load_rules(db, user_id) -> Vec<UserRule>;   // active, ordered
```

Preview, retroactive apply, import confirm, and Plaid sync all call `apply_rules`. Matching is *never* duplicated in SQL — Postgres `UPPER()`/`LIKE` and Rust `to_uppercase()`/`contains` disagree on accent/case edges (Ñ, É are routine in these descriptors), and any divergence breaks dry-run-vs-apply parity, which is the safety story. Preview/apply do a coarse SQL prefilter (user + optional account/currency scope) and filter in Rust; at this deployment's row counts (single household) that is comfortably cheap.

**Path 1 — statement import** (`imports.rs::confirm_handler`, :390): load `Vec<UserRule>` once before the row loop (beside the learned-map build at :485); per row, evaluate on the same basis learn-from-edits uses (`original_description ?? description`, :566-568). The insert (:605-630) gains binds: `user_description`, the two `*_source` and two `*_rule_id` columns. Precedence inline: `user_category = rule.category.or(learned)` with source `'rule'`/`'learned'` accordingly. The `ON CONFLICT` clause continues to touch only `balance_after` (:608-609) — **re-imports stay idempotent and never clobber**, same contract as today (:580-582).

**Path 2 — Plaid sync** (the gap): `sync_one_institution` loads the rule set once per institution (user id already in hand at `sync.rs:574`) and passes `&[UserRule]` into `upsert_plaid_transaction`. Outcome fields join the INSERT column list; the `DO UPDATE SET` list (`sync.rs:1141-1156`) deliberately does **not** include any `user_*` column, so, like today, a re-sync/pending→posted refresh never touches them. Rule application on this path is *insert-only*, mirroring the import path — re-evaluating on conflict would let a later-disabled rule silently revert historical rows on re-sync, violating the invariant. (Posted transactions arriving under a new `transaction_id` are fresh inserts and get rules applied; a re-synced row whose description changes enough to newly match a rule is caught by retroactive preview, not by the conflict path. Documented trade-off.) The secondary investment-income insert (`sync.rs:1750-1776`) is left alone in MVP — it hardcodes `'INCOME'`, which is correct for dividends.

**Path 3 — retroactive**: only via the confirmed apply (§4). Manual-add and split-children inserts (`accounts.rs:1516`, `:1721`) are deliberately untouched in MVP — the user is typing those rows by hand in that moment.

After a successful apply, publish `RealtimeEvent::TransactionsChanged` (precedent: sync + import confirm, FUTURE.md §G) so open tabs refetch.

---

## 4. The dry-run diff contract

New module `backend/src/api/rules.rs`, nested at `/api/rules` on the protected router; mutations owner-gated (`require_owner`); static routes `/preview` and `/reorder` declared **before** `/{id}` (house rule).

```
GET    /api/rules                 → list (priority order, incl. inactive)
POST   /api/rules                 → create           — mutates ZERO transactions
PATCH  /api/rules/{id}            → edit / activate / deactivate — mutates ZERO transactions
DELETE /api/rules/{id}            → delete           — mutates ZERO transactions
PATCH  /api/rules/reorder         → { ordered_ids: [...] } rewrites priorities
POST   /api/rules/preview         → dry-run (rule definition inline — works before create AND for edits)
POST   /api/rules/{id}/apply      → { preview_token } — the ONLY endpoint that rewrites history
```

**Preview** (`POST /api/rules/preview`, body = full rule definition):

1. Prefilter candidate rows by `user_id` (+ account/currency scope) selecting only the columns `RuleInput` and change-computation need.
2. Run `apply_rules` per row; compute per-field changes against the *effective* current values, honoring the manual-protection predicate.
3. Respond:

```json
{
  "matched": 37,
  "category_changes": 22,
  "description_changes": 31,
  "skipped_manual": 4,
  "fx_transfer_legs": 1,
  "derived_merchant_key": "STARBUCKS REFORMA",
  "samples": [ { "id", "date", "account_name", "display_description",
                 "old_category", "new_category",
                 "old_description", "new_description" } ],
  "preview_token": "…", "expires_in_seconds": 900
}
```

(`fx_transfer_legs` warns when matched rows are legs of `cash_fx_transfers`;
`samples` capped at 50; `derived_merchant_key` feeds the merchant_key matcher UI.)

4. Server-side, store in Redis (already in `AppState` — `lib.rs:14`; precedent: encrypted WebAuthn flow state): key `rules:preview:{token}` → `{ user_id, rule_fingerprint, changed_ids: [...] }`, TTL 15 min. `rule_fingerprint` is a hash of the canonicalized rule definition (matcher + scope + actions — not the id), so a token minted before create remains valid for the identical just-created rule.

**Apply** (`POST /api/rules/{id}/apply`):

- Token must exist, belong to the caller, and its fingerprint must equal the rule's *current* definition — a rule edited after preview ⇒ `409 preview stale, re-run`. Token is consumed atomically (`GETDEL`): single-use, so a double-click can't double-fire.
- In one DB transaction, update **exactly the previewed id set**, re-asserting the protection predicate in SQL (a row manually edited between preview and apply is skipped, not clobbered):

```sql
UPDATE transactions
   SET user_category = $1, user_category_source = 'rule', user_category_rule_id = $2
 WHERE id = ANY($3) AND user_id = $4
   AND NOT (user_category IS NOT NULL AND user_category <> ''
            AND (user_category_source = 'manual' OR user_category_source IS NULL));
-- analogous statement for user_description
```

- Response: `{ updated_category, updated_description, skipped }` — `skipped > 0` is surfaced in the UI, honestly.
- **Rows that arrived between preview and apply are NOT touched** (not in the id set). They're covered going forward by paths 1–2 if inserted after rule creation; the management screen's "Preview retroactive" re-run shows any residue. Deterministic beats greedy.
- Apply is idempotent in effect (same values); replay is blocked by token consumption anyway.

**Invariant restated as an implementable rule:** the only statement anywhere in the codebase that writes `user_*` with `*_source='rule'` onto *pre-existing* rows is the apply handler above, and it only ever runs with a valid, fingerprint-matched, single-use preview token.

---

## 5. UX surfaces (en + es-MX from day one)

All strings in `app_en.arb` + `app_es.arb`, key prefix `rule*`; multi-placeholder strings must respect the gen-l10n **placeholder alphabetization trap** (flutter-frontend SKILL §2). Plain Flutter state, cards dumb/injected, `ApiService` for all HTTP (never top-level `http.*` — Android cookie trap).

**1. "Save as rule" in the detail panel** (`frontend/lib/widgets/transaction_detail_panel.dart`). The panel already owns the category editor and rename affordances via `TransactionDetailHost` (`onUpdate` :57-64, `renameTransaction` :139-142). Add a "Save as rule…" action (kebab entry + a post-edit inline chip "Make this a rule"). It opens the **RuleEditorSheet** pre-filled:

- matcher: `contains`, value = `counterparty_name ?? merchant_name ?? description` (trimmed); a segmented control offers `merchant_key`, whose derived key + match count come from the preview response (`derived_merchant_key`);
- actions: `set_category` = the row's current effective category (if the user just changed it), `set_description` = current `user_description` if set;
- scope: unset by default; chips for this-account / this-currency.

**2. RuleEditorSheet with live diff.** A debounced `POST /rules/preview` fires as the user edits; the bottom section renders the **RulePreviewDiff** component: count line ("Matches 37 · changes 22 categories, 31 names · 4 skipped as manual edits"), an expandable sample list (date · account · description, before→after chips per field), and a warning banner when `fx_transfer_legs > 0`. Two primary buttons, both disabled until a preview completes: **Save rule** (forward-only) and **Save & apply to N past transactions** (create → apply with token; a confirm dialog restates N). This is the safety mechanism, so the diff is not collapsible-by-default polish — it is always visible before apply.

**3. Rules management screen.** New `frontend/lib/screens/rules_screen.dart`, reached from the Settings tab row next to Hidden items (`settings_cards.dart:317` is the navigation precedent). `ReorderableListView` (drag = `PATCH /reorder`); each tile: generated summary ("Description contains 'OXXO GAS' → Transportation"), scope chips, active `Switch` (PATCH), kebab: Edit (same RuleEditorSheet, edit-mode preview included) / Preview retroactive / Delete. Delete confirm copy states plainly: "Past changes made by this rule are kept."

**4. ApiService**: new part file `frontend/lib/services/api_service/rules.dart` following the existing part pattern (`transactions.dart`).

---

## 6. Test plan

**Backend** — unit tests in `services/rules.rs` + integration `backend/tests/rules_endpoints.rs` (pattern: `tests/dashboard_endpoints.rs` — real middleware stack, `oneshot`, `#[serial]` + advisory lock, loud-skip only when `PATRIMONIO_TEST_DATABASE_URL` is unset):

- **Matcher unit tests:** each `match_type`; case/accent insensitivity (Ñ/É descriptors); `merchant_key` parity with `categorize::merchant_key`; scope axes (account, currency, direction, ABS-amount range); first-match-wins per field; priority + created_at + id tie-break; inactive rules ignored.
- **Precedence matrix (integration):** seed rows in each provenance state {manual, legacy-NULL-source, learned, rule, curated-only, plaid-PFC-only} × {forward insert, retroactive apply} → assert the §2 table cell-by-cell. Named tests, e.g. `manual_edit_survives_rule_apply`.
- **Dry-run vs apply parity:** preview id set == rows actually updated on fixtures; row manually edited between preview and apply → skipped and counted; rule edited after preview → 409; token reuse → rejected; expired token → 409.
- **Zero-mutation invariant:** `POST /api/rules` / PATCH / DELETE leave a checksum of `transactions` unchanged.
- **Plaid-path application:** call `upsert_plaid_transaction` (made `pub(crate)` for tests) with canned Plaid JSON + a rule set → `user_category`/`user_description` + provenance stamped on insert; second call (conflict) with a mutated description → `user_*` untouched.
- **Idempotent re-import:** confirm the same batch twice → duplicate path leaves rule-applied values intact; learned map excludes `'rule'`/`'learned'` rows (regression test for the feedback loop).
- **Security:** cross-tenant (user B's rules never match/update user A's rows in preview, apply, or forward paths); read-only user → 403 on all mutations; CSRF via the shared `req()` helper.

**Frontend** (`flutter test`):

- RuleEditorSheet prefill from a tx map (counterparty → merchant → description fallback ladder);
- RulePreviewDiff widget test from a canned preview payload: counts, before→after rows, skipped-manual line, fx-transfer warning — pumped with `localizationsDelegates` in **both** locales;
- save-as-rule flow with mocked ApiService: apply button gated on a completed preview; confirm dialog restates the previewed count;
- l10n completeness via the existing convention suite.

**Smoke:** extend `scripts/smoke.cjs`: create rule → preview → apply → assert a seeded row's category changed and a manually-edited seeded row didn't.

---

## 7. Phasing

**MVP (~1 week, genuinely shippable):**

- Day 1 — migration + model + `services/rules.rs` matcher + unit tests.
- Day 2 — `api/rules.rs` CRUD + preview + Redis-token apply + core integration tests.
- Day 3 — forward paths (imports confirm + Plaid sync) + precedence matrix + learned-map exclusion.
- Day 4 — RuleEditorSheet, save-as-rule affordance, `api_service/rules.dart`, l10n (en + es-MX).
- Day 5 — RulesScreen (list/reorder/disable/delete), smoke, UI walkthrough both locales.

MVP includes all four matchers, all four scope axes, both actions, both forward paths, the full dry-run/apply contract, and rule management. That satisfies the FUTURE.md acceptance criteria verbatim (Banamex rule auto-applies on next import AND retroactively via previewed confirm; nothing historical changes without confirm).

**MVP deliberately punts:** regex matching; revert-applied-changes on delete/disable (itself dry-runnable — full scope); rule hit-count/last-matched stats; application on the manual-add path and split children; import-preview annotation ("this row will match rule X") — rules land at confirm and are visible immediately after; "you've edited 4 similar rows — create a rule?" nudges; Plaid conflict-path re-evaluation on description change; a rule test-bench ("paste a descriptor, see which rule fires").

**Full L scope** = MVP + revert machinery + stats + test-bench + nudges, with regex only on explicit owner sign-off.

---

## 8. Riskiest assumptions & open questions for the owner

1. **Rename-vs-categorize scope.** `set_description` rides `user_description` — display-only. The subscriptions detector and `_similarTransactionIds` cluster on the **raw** `description`, so renames don't perturb detection (good) but also don't consolidate clusters (a renamed cluster still shows N raw variants in "similar rows"). Acceptable, or should rename rules eventually feed a normalized-merchant concept?
2. **Regex: confirm OUT for v1** (rationale §1). If a real descriptor defeats `contains`+`merchant_key`, that's the trigger to revisit.
3. **Transfers.** Should rules be allowed to match rows whose effective category is `TRANSFER_*` or that are legs of `cash_fx_transfers`? Recategorizing a transfer leg re-enters it into cash-flow totals (the anti-joins in `spending.rs` key off category). Design says **allow + warn in the diff** (`fx_transfer_legs` count); blocking instead is a one-line predicate if you prefer.
4. **Legacy provenance.** Pre-existing `user_category` rows (including historical learned-map writes) are all treated as manual-protected. Conservative — rules will under-apply on old learned rows until re-touched. OK?
5. **Delete semantics.** Applied values persist after rule deletion (Monarch-style). Want the dry-runnable revert in full scope, or never?
6. **Amount-range currency.** Ranges compare ABS(native amount); a range without a currency scope compares MXN and USD magnitudes raw. UI nudges to set currency when a range is set — should it be *required* instead?
7. **`set_category` value space.** Rules store exactly what the transaction editor stores in `user_category` today (the `distinctCategories()` suggestion hub feeds the picker, so no second taxonomy). If you want category normalization (pretty label vs PFC code), that's a separate cleanup, not this feature.
8. **Biggest schedule risk:** the preview/apply staleness contract (Redis token + fingerprint + re-asserted protection predicate) is the novel machinery; everything else is established house patterns. If Day 2 runs long, forward paths (Day 3) can ship behind CRUD with retroactive apply following a day later — forward-only rules are still safe (they never rewrite history by definition).

---

## Critical files for implementation

- `backend/src/api/imports.rs` — learn-from-edits map (:485-505), insert-time application (:583-590), the confirm insert to extend (:605-630)
- `backend/src/services/sync.rs` — `upsert_plaid_transaction` (:1049-1181), the gap path; rule-set load-once at the :574 call site
- `backend/src/services/categorize.rs` — curated engine + `merchant_key` (:716-769) the rules layer sits above and reuses
- `backend/src/api/accounts.rs` — single/batch PATCH handlers (:768-830, :1052-1109) that must stamp `'manual'` provenance
- `frontend/lib/widgets/transaction_detail_panel.dart` — the save-as-rule affordance host (`TransactionDetailHost`, :31-161)
