---
name: work-tracking
description: How to track project progress, make decisions, and transition between phases in Patrimonio
---

# Work Tracking

## Finding what to work on
1. Read `work/CURRENT.md` — the "you are here" pointer: a reverse-chronological
   snapshot log, newest dated entry at the top
2. `work/HANDOFF.md` is the cold-start companion (prod state, how to verify/ship);
   `work/NEXT.md` / `work/FUTURE.md` hold the backlog
3. If a phase spec is in play (`work/phases/PHASE-N-*.md`), work through its
   deliverables checklist

## Recording completed work
1. Tick the relevant `[x]` items in the phase spec, if one applies
2. Add a new dated entry at the **top** of `work/CURRENT.md` (below the header)
   summarizing what shipped and why; update the "Last updated" line
3. Commit with a conventional-commit `docs:` message

## Keeping the routing docs true (maintenance rules)

A cold-start agent trusts HANDOFF/NEXT before it reads anything else, so a
stale entry there is actively misleading — worse than no entry:

- **When something ships or prod state changes, update the doc that claims
  otherwise in the same sitting:** delete the item from `work/NEXT.md`,
  refresh `work/HANDOFF.md`'s TL;DR (HEAD, deployed-through commit, APK cut),
  and record any significant technical choice in `work/DECISIONS.md` (the
  2026-07-24 → 2026-08-02 gap where four decisions lived only in CURRENT.md
  prose is the failure mode).
- **Rotate `work/CURRENT.md`** when it stops being readable in one sitting
  (~1,000+ lines): move entries older than the current/previous month into
  `work/archive/CURRENT-YYYY-MM.md` **verbatim** (no summarizing, no edits)
  and leave a one-line pointer at the bottom of CURRENT.md. Precedent:
  `work/archive/CURRENT-2026-06.md`.

## Making architectural decisions
When making a significant technical choice:
1. Open `work/DECISIONS.md`
2. Add a new entry with the format:
   ```
   ## DEC-XXX: Short Title
   **Date:** YYYY-MM-DD
   **Status:** Accepted | Rejected | Superseded by DEC-YYY
   **Context:** Why this decision was needed
   **Decision:** What was decided
   **Rationale:** Why this option won
   **Trade-off:** What we knowingly gave up
   ```
3. Reference the decision number in related code comments

## Phase specs format
Each phase spec (`work/phases/PHASE-N-*.md`) should have:
- **Goal** — one-sentence objective
- **Deliverables** — checklist of items (`[ ]` / `[x]`)
- **Success Criteria** — how we know it's done
- **Test Plan** / **Open Questions** — where relevant

Don't enumerate phases here — `ls work/phases/` is the list (14+ so far), and
`work/CURRENT.md` says where things actually stand.
