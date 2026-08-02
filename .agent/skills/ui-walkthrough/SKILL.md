---
name: ui-walkthrough
description: How to verify UI changes in the real running app — headless browser walkthroughs, screenshot evidence, e2e smoke passes
---

# UI Walkthrough

Widget tests and `flutter analyze` never exercise the real app: the served web
bundle, the same-origin `/api` contract, session auth, live data, CanvasKit
rendering. When a change needs proof it works **in the running app** — after
risky refactors, before calling visual work done, or when the user asks for
screenshots — run a headless walkthrough.

**The mechanics live in `scripts/walkthrough/`** (same-origin proxy with
WebSocket passthrough, session-cookie minting, Playwright setup, semantics
activation). Read `scripts/walkthrough/README.md` for the exact commands; this
skill is about *when* and *what* to check, and the ground rules.

## When to use

- Verifying a frontend change actually renders/behaves in the served app (a
  passing widget test is not that).
- Screenshot evidence for the user ("show me the new card").
- E2e smoke after risky changes: API contract changes, auth/session work,
  l10n sweeps, theme/color refactors, dependency bumps.
- UX evaluation passes (spacing, truncation, overflow at real viewports).

Not for: things a widget test covers faster, or anything against prod (prod
sessions are a human-approved procedure — see the memory notes, not this rig).

## Ground rules

1. **Dev DB only.** `mint_session.sh` writes to the local Postgres on :5442.
   Never point the rig at prod or thelab.
2. **Walkthroughs are read-only with respect to source.** A walkthrough
   *observes* the app; it must not edit code mid-pass. If you find a bug, finish
   (or abort) the pass, then fix and re-run — otherwise your screenshots mix
   before/after states and prove nothing.
3. **Drive `claude_dev`** (email claude_dev@local.test — data-rich, has seeded
   QA fixtures for spikes/subscriptions/balance-moves). **Never the `nick`
   account** (the human's real data). Reuse the seeded fixtures; don't reseed
   blindly.
4. **Delete minted sessions when done** (the mint script prints the cleanup
   command), and tear down the proxy/backend you started.
5. Distinguish app bugs from **rig artifacts** before reporting: a proxy that
   drops `X-Requested-With` fakes broken persistence (403s), dropping
   `X-Total-Count` fakes broken totals, no WS passthrough fakes broken
   realtime. `scripts/walkthrough/proxy.py` handles all three — if you see
   these symptoms, first confirm you're actually running it.

## The standard checklist

A full walkthrough covers, at minimum:

- **All 8 tabs**: Overview, Portfolio, Transactions, Cash flow, Projections,
  Tax planning, Lending, Settings.
- **Both locales**: en + es-MX (switch via the app-bar kebab → language).
  Watch for clipped/overflowing Spanish strings and unformatted money.
- **Both themes**: light + dark. Watch for hardcoded-color regressions.
- **Both form factors** when layout changed: desktop 1440×900 (left
  NavigationRail) and phone 390×844 (bottom bar: Home / Invest / Activity /
  Cash / More — note the bottom "More" sheet and the app-bar kebab are
  DIFFERENT menus).
- **Console-error tally**: capture browser console throughout; end the pass
  with a count. Zero errors is the bar — report every non-zero finding with
  the page it happened on. (Expected noise: none. The app runs clean.)

Scale down deliberately for a targeted pass (one screen, one theme), and say
so in the report. Screenshots go to the session scratchpad, not the repo.

## Gotchas that waste hours

- **Semantics start OFF.** No `flt-semantics` nodes exist until you click the
  off-viewport `flt-semantics-placeholder` via
  `page.eval_on_selector('flt-semantics-placeholder', 'el => el.click()')` —
  a probe that skips this sees an "empty" app. Details in the README.
- Match semantics nodes by **textContent**, shortest match, `force=True`;
  virtualized rows need scrolling into view first; a few widgets are absent
  from semantics entirely → click by pixel coords off a screenshot.
- Boot-hang at "Loading engine…" = stale `.dart_tool/flutter_build` cache →
  `flutter clean` + rebuild, not an app bug.
- ~4 concurrent headless Chromiums is the comfortable ceiling on this VM;
  `free -h` before stacking them on top of builds.

## Definition of done

- [ ] Rig from `scripts/walkthrough/` (not an ad-hoc proxy) against the dev
      backend on :8080, driving `claude_dev`
- [ ] Checklist scope stated: full 8-tab pass, or the deliberate subset
- [ ] Locales/themes covered (or subset justified)
- [ ] Console-error tally reported (count + where)
- [ ] Findings separated into app bugs vs rig artifacts
- [ ] Minted session deleted; proxy and any backend you started stopped
- [ ] No source edits made mid-walkthrough
