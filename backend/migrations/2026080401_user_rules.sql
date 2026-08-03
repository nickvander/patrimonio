-- User rules engine (MVP): explicit, persisted, user-defined rules that
-- categorize and/or rename transactions, consulted on BOTH write paths
-- (statement-import confirm and Plaid sync) and applicable retroactively
-- only behind a previewed, confirmed dry-run diff. See
-- work/RULES_ENGINE_DESIGN.md and DEC-027 / DEC-028.
--
-- Non-negotiable invariant this schema exists to make enforceable:
-- creating, editing, enabling, disabling or deleting a rule mutates ZERO
-- existing `transactions` rows on its own. The provenance columns below
-- are what turn "a human edit always wins" from a convention into a SQL
-- predicate.
--
-- Follows the `recurring_rules` precedent (2026072302): user-scoped,
-- `active` flag, access-path index.
CREATE TABLE IF NOT EXISTS user_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Matcher. Evaluated case-/accent-insensitively in Rust (ONE
    -- implementation — services/rules.rs; matching is never duplicated in
    -- SQL, because Postgres UPPER()/LIKE and Rust to_uppercase()/contains
    -- disagree on accent edges (Ñ, É are routine in these descriptors) and
    -- any divergence would break dry-run-vs-apply parity, which is the
    -- entire safety story). `contains`/`starts_with`/`exact` test
    -- description, original_description, merchant_name and
    -- counterparty_name; `merchant_key` compares
    -- categorize::merchant_key(original_description ?? description) — the
    -- same basis learn-from-edits uses in imports.rs.
    --
    -- No regex in v1: a catastrophic-backtracking pattern would wedge the
    -- per-row Plaid sync path, and contains/starts_with/merchant_key
    -- already cover the es-MX descriptor cases (SPEI strings, "PAGO OXXO"
    -- variants, RFC codes). DEC-027.
    match_type  TEXT NOT NULL CHECK (match_type IN
                    ('merchant_key','contains','starts_with','exact')),
    match_value TEXT NOT NULL CHECK (length(btrim(match_value)) > 0),

    -- Scoping. NULL = unrestricted.
    account_id  UUID REFERENCES accounts(id) ON DELETE CASCADE,
    currency    TEXT,
    direction   TEXT CHECK (direction IN ('inflow','outflow')),
    -- Compared against ABS(amount) in the row's NATIVE currency; positive
    -- magnitudes. Direction is a separate axis, matching categorize.rs's
    -- own sign-awareness.
    amount_min  DECIMAL(15,2) CHECK (amount_min IS NULL OR amount_min >= 0),
    amount_max  DECIMAL(15,2) CHECK (amount_max IS NULL OR amount_max >= 0),
    CHECK (amount_min IS NULL OR amount_max IS NULL OR amount_max >= amount_min),

    -- Actions. At least one. Values live in the SAME value space the
    -- transaction editor writes to user_category / user_description today —
    -- no new taxonomy, so every existing reader (EFFECTIVE_CATEGORY_SQL,
    -- spending, tax, exports, the frontend display ladder) keeps working
    -- untouched.
    set_category    TEXT,
    set_description TEXT,
    CHECK (set_category IS NOT NULL OR set_description IS NOT NULL),

    -- Deterministic order: priority ASC, created_at ASC, id ASC. New rules
    -- append at the end (priority = max + 10); the reorder endpoint
    -- rewrites priorities.
    priority   INTEGER NOT NULL DEFAULT 0,
    active     BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Both the management list and every write path read "my active rules, in
-- priority order" — index the access path.
CREATE INDEX IF NOT EXISTS idx_user_rules_user_active
    ON user_rules(user_id, active, priority);

-- Provenance on transactions: WHO set user_category / user_description.
-- A field is manual-protected iff its value is non-empty AND its source is
-- 'manual' or NULL (legacy) — no rule path may ever overwrite that.
-- ON DELETE SET NULL (not CASCADE): deleting a rule KEEPS the values it
-- applied (DEC-028). The residue stays `*_source = 'rule'`, so it remains
-- machine-owned and freely overwritable by a future rule, while a human
-- edit stays untouchable. Deleting a rule must never rewrite history —
-- that would violate the invariant above.
ALTER TABLE transactions
  ADD COLUMN IF NOT EXISTS user_category_source TEXT
      CHECK (user_category_source IN ('manual','rule','learned')),
  ADD COLUMN IF NOT EXISTS user_category_rule_id UUID
      REFERENCES user_rules(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS user_description_source TEXT
      CHECK (user_description_source IN ('manual','rule')),
  ADD COLUMN IF NOT EXISTS user_description_rule_id UUID
      REFERENCES user_rules(id) ON DELETE SET NULL;

-- Legacy rows: everything set before this feature is conservatively
-- treated as manual (historical learn-from-edits writes are
-- indistinguishable from real human edits at this point). Conservative in
-- the safe direction: rules can only UNDER-apply on old learned rows,
-- never clobber a human edit.
UPDATE transactions SET user_category_source = 'manual'
    WHERE user_category IS NOT NULL AND user_category <> '' AND user_category_source IS NULL;
UPDATE transactions SET user_description_source = 'manual'
    WHERE user_description IS NOT NULL AND user_description <> '' AND user_description_source IS NULL;
