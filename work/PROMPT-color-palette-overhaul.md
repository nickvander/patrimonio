# Paste-ready prompt — color palette overhaul

> Copy everything between the `---` lines into a new Claude Code session. The plan it references lives at `work/FUTURE.md` § "Color palette overhaul".

---

You're picking up Patrimonio, a personal-finance dashboard. Stack:
Flutter web frontend, Rust axum backend, Postgres, Plaid.

Worktree:  /home/nickvander/patrimonio/.claude/worktrees/<this-worktree>
Branch:    your local branch (pushes go to origin/main)
Live UI:   http://localhost:3000   API: http://localhost:8080
Build:     bash scripts/dev-up.sh frontend api   # wraps setup-env + docker compose
Validate:  cd <worktree>/frontend && flutter analyze (must be 0 issues)

READ FIRST — this is the brief, not training data:
- work/FUTURE.md  → § "Color palette overhaul (dark + light) and chart hover polish"

That section has the full plan: pain points with file:line, the current
token inventory, design direction, acceptance criteria, and a 6-step
implementation outline. Read it before you start.

WHAT THE USER ACTUALLY ASKED FOR

Verbatim, so nothing gets paraphrased away:

> Revise the color palettes for dark mode and light mode. Dark mode
> looks good but has issues — for example, on the Overview tab, if I
> hover over the net-worth graph, the popup can't really be seen in
> dark mode. Hovering over the chart feels mechanical too — not all
> points show the hover, what are the best design practices on that?
>
> Light mode: the contrasts between the backgrounds and text don't
> look great. Make a nice clean, innovative, modern, expressive and
> good looking palette that plays well with the dark mode too.

YOUR JOB

Land this in focused commits per the work/FUTURE.md plan steps. Roughly:

1. Audit the call-site palette (one commit, mostly research output captured
   in a comment block or doc).
2. Introduce `frontend/lib/theme/palette.dart` with brightness-aware
   accent + surface tokens (one commit).
3. Migrate `ThemeColorsExt` (frontend/lib/utils/theme_colors.dart) to
   delegate to the new palette (one commit).
4. Fix the chart tooltips (legibility) and hover responsiveness
   (one commit) — this is the single highest-impact UX fix in the
   batch, do it early so you can verify it visually.
5. Add the WCAG-AA contrast unit test so the palette doesn't quietly
   regress (one commit).
6. Visual smoke across every tab in both modes; capture any leftovers
   in a follow-up commit if needed.

KEY FILES (most-traffic, in approximate order to touch)

- frontend/lib/main.dart                    — light + dark ThemeData
- frontend/lib/utils/theme_colors.dart      — ThemeColorsExt tokens
- frontend/lib/widgets/net_worth_card.dart  — tooltip bug + hover bug
- frontend/lib/screens/wealth_projection_screen.dart — same tooltip shape
- frontend/lib/components/trends_chart.dart — bar-chart tooltips
- frontend/lib/components/allocation_heatmap.dart — uses accent colors directly

NON-NEGOTIABLES (will be reverted if violated)

- Sentence case everywhere user-facing. "Total value", "Cost basis",
  not "Total Value"/"Cost Basis".
- Card chrome standard: elevation: 4 (dark) / 2 (light theme already
  bumps this), padding: EdgeInsets.all(24), RoundedRectangleBorder
  radius 16-24.
- Spacing rhythm: 4/8/12/16/20/24/32.
- Tabular figures (FontFeature.tabularFigures()) on every currency
  number so columns line up.
- maxLines + overflow: TextOverflow.ellipsis on every Text inside a
  Row/Expanded chain.
- LayoutBuilder breakpoints, not MediaQuery.sizeOf, when a component
  shouldn't know which page it lives on.
- Use ThemeColorsExt (now backed by the new palette) for text colors;
  don't reintroduce Colors.white* literals.
- WCAG AA (4.5:1 normal, 3:1 large) on every body / subtitle pair in
  both brightnesses. There's a test for this — keep it green.

OUT OF SCOPE for this session unless explicitly asked

- Authentication / multi-user
- iOS / Android native build
- Schema rewrites (additive migrations only)
- Replacing fl_chart or any other major dep
- Re-doing the Other-group classifier (utils/account_category.dart)
  or the const-literals lint pass (separate FUTURE.md items)

WHEN YOU'RE DONE

- Several focused commits on origin/main (one per plan step is fine).
- A short follow-up message: what shipped, what's still open from the
  FUTURE.md plan, and any new pain points you noticed while
  re-skinning the app.

If the user pushes back on a specific colour choice, treat their
intuition as data — they spend more time looking at the UI than the
analyzer does. Iterate on the palette in `frontend/lib/theme/palette.dart`
rather than at the call sites.
