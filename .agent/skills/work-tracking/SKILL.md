---
description: How to track project progress, make decisions, and transition between phases in Patrimonio
---

# Work Tracking

## Finding what to work on
1. Read `work/CURRENT.md` — this is the "you are here" pointer
2. Open the phase spec referenced in CURRENT.md (e.g., `work/phases/PHASE-2-PLAID.md`)
3. Work through the deliverables checklist in that phase spec

## Completing a phase
1. Mark all items as `[x]` in the phase spec
2. Update `work/CURRENT.md`:
   - Move the completed phase to "What's Done"
   - Update "What's Next" to point to the next phase
   - Update the date and status at the top
3. Commit: `git commit -m "docs: complete Phase N, start Phase N+1"`

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
   **Alternatives:** What else was considered
   ```
3. Reference the decision number in related code comments

## Phase specs format
Each phase spec (`work/phases/PHASE-N-*.md`) should have:
- **Goal** — one-sentence objective
- **Deliverables** — checklist of items (`[ ]` / `[x]`)
- **Success Criteria** — how we know it's done
- **Notes** — anything else relevant

## Current phases
1. PHASE-1-FOUNDATION — Backend scaffold, Docker, DB ✅
2. PHASE-2-PLAID — US financial data integration
3. PHASE-3-DASHBOARD — UI charts and breakdowns
4. PHASE-4-MEXICO — CSV/PDF import for Mexican institutions
5. PHASE-5-DEPLOY — Mobile, GCP, production hardening
