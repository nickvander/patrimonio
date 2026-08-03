# Feature research — 2026-08-03

## Executive summary

| # | Title | Score (/30, moat ×2) | Effort | One-line pitch |
|---|-------|------|--------|----------------|
| 1 | Household continuity dossier (switch deferred) | 25 | M | One button turns the FBAR inventory the app already maintains into a bilingual, printable "open in emergency" packet. |
| 2 | User rules engine + auto-categorization (extension) | 24 | L | Fix a garbled Banamex descriptor once — explicit, dry-runnable rules make every future import land clean. |
| 3 | Bills calendar + short-horizon balance forecast (extension) | 24 | M | Fills the 1–90-day gap between recurring detection and FIRE projections, per currency: "move USD→MXN before the 15th." |
| 4 | Net-worth change attribution: FX vs market vs flows | 24 | M | Answers "was it the peso or was it me" from data that is already fully stored. |
| 5 | Transfer fee/spread analytics ("cost of being cross-border") | 24 | S | An S-effort aggregate over shipped implied-vs-spot machinery: "you paid $412 to move your own money last year." |
| 6 | Guided statement reconciliation at import (extend-backlog) | 24 | M→L | Upgrades continuity.rs's advisory checks into YNAB's beloved matches-to-the-centavo ritual for the nine MX banks. |
| 7 | Sub-5-second mobile quick-entry capture | 23 | M | Cash-heavy MX life + an APK already in the pocket; two 900★-class companion apps exist solely because competitors' entry is slow. |
| 8 | FX-aware Sankey cash-flow diagram | 23 | M | The one screenshot-worthy chart in personal finance, with a two-currency FX node nobody else can draw. |

The sweep's dominant finding is that Patrimonio's shipped surface was systematically underestimated: the best candidates are not new features but increments riding verified seams (cash_fx_transfers, balance_snapshots, recurring.rs, continuity.rs, categorize.rs), which is why four of the eight picks were reframed from "new" to "extension" during skeptic review. The strongest demand evidence in the pool (rules engine, bills calendar, quick entry) verified to the digit via the GitHub API, while several emotionally appealing candidates leaned on citations that didn't say what was claimed — those were downgraded or cut rather than laundered. The moat-defining picks (attribution, dossier, fee analytics, reconciliation) share a shape: pure local computation over data only a US+MX household accumulates, which no competitor serves and no SaaS can match on privacy. Four skeptic survivors were cut on PM judgment — mostly for headline promises the current data cannot keep — and are recorded in Appendix A with the disagreement noted.

## Briefs

### 1. Household continuity dossier (inactivity switch deferred)

**Problem** — One spouse runs the finances; a binational estate is the worst case for the survivor: FBAR-reportable MX accounts, CetesDirecto, two tax regimes, 14+ institutions the other spouse may not know exist. Hand-maintained "death binders" go stale immediately.

**Demand evidence** — Strong and verified. Kubera markets its Dead Man's Switch on its homepage (https://www.kubera.com/), confirmed as a standout differentiator by two independent 2026 reviews (https://www.wallstreetzen.com/blog/kubera-app-review/, May 2026; https://wallethacks.com/kubera-review/, updated July 2026). Bogleheads recurrence verified across a decade: https://www.bogleheads.org/forum/viewtopic.php?p=8741742 (staleness stated verbatim, active April 2026), https://www.bogleheads.org/forum/viewtopic.php?t=346184, https://www.bogleheads.org/forum/viewtopic.php?t=468584, https://www.bogleheads.org/forum/viewtopic.php?t=188292, plus institutional-level recurrence at https://boglecenter.net/bogleheads-chapter-series-documenting-financial-information-for-surviving-spouse-executor/.

**Competitor landscape** — Kubera (cloud, $150/yr) is essentially alone; no OSS/self-hosted tool has anything. Everyone else uses Word docs and paper binders that rot.

**Proposed Patrimonio shape** — Dossier-export half only: a new export endpoint aggregating accounts/institutions/loans/people + free-text instructions, bilingual (en + es-MX) via the already-bilingual backend-HTML pattern in tax_exports.rs (FBAR worksheet, lang toggle at :58-60) and loans.rs (:2836-2848). The inactivity switch is explicitly deferred: no SMTP/email infra exists anywhere in the codebase, and the spouse already has a read_only login (invites.rs). staleness.rs's daily cron is the precedent if a switch is ever wanted.

**Effort** — M. Driver: aggregation breadth + bilingual rendering; all generation patterns are shipped.

**Riskiest assumption** — That an off-server printable inventory is valuable without credentials/documents/contacts. The self-hosted ethos actually inverts in its favor: the server dies with its admin, so the off-server snapshot is the missing complement.

**Joy rationale** — Peace of mind is the deepest delight a finance app can sell; "the guilt-inducing chore becomes a standing button" is a genuine *finally* moment.

**Skeptic's challenge** — Sharpest point, accepted: the dossier is an inventory, not an access kit — Bogleheads threads stress that access/process (institutions lock logins on death) is the hard half, so the deliverable is materially narrower than the Kubera comparison implies. Kept because the executor's-checklist half (the FBAR inventory) is exactly what Patrimonio uniquely maintains, and it's the half that rots in hand-built binders.

### 2. User-facing rules engine + auto-categorization (save-edit-as-rule, dry-run) — extension

**Problem** — Dirty es-MX statement descriptors (SPEI strings, "PAGO OXXO" variants, RFC codes) across nine MX bank parsers are the single biggest recurring chore; today only a hardcoded curated engine (categorize.rs, 1,109 lines) plus merchant-key learn-from-edits cover it — there is no user-defined, persisted, previewable rule.

**Demand evidence** — Strongest converged evidence in the sweep, verified: https://github.com/sakowicz/actual-ai (502★ bolt-on existing solely to categorize Actual transactions), https://github.com/bahuma20/firefly-iii-ai-categorize (220★ parallel), https://news.ycombinator.com/item?id=39392428 ("once it's done things happen automatically" — note: ~157 comments, not the researcher's claimed 400+), https://github.com/actualbudget/actual/issues/3606 (open templating/dry-run thread; "a dry-run is missing"), https://help.monarch.com/hc/en-us/articles/360048393372-Transaction-Rules, https://support.lunchmoney.app/setup/rules, https://support.lunchmoney.app/setup/categories/auto-categorization. Caveat preserved: https://github.com/firefly-iii/firefly-iii/issues/2575 was cited as an outstanding ask but was actually closed as fixed in 2019 — it validates the gesture as table stakes, not unmet demand.

**Competitor landscape** — Universal in loved apps (Monarch/Lunch Money explicit rules, Copilot ML, YNAB payee memory); Firefly's engine is powerful but arcane. Nobody does bilingual es-MX merchant normalization.

**Proposed Patrimonio shape** — Extend, don't replace: user_rules table + CRUD, consulted before curated categorize.rs; "save as rule" affordance in transaction_detail_panel.dart; rename actions ride the shipped cluster-rename machinery; retroactive apply gated behind a dry-run diff; extend coverage to the Plaid path (services/sync.rs — where learning currently does not apply).

**Effort** — L. Driver: a trustworthy dry-run diff over both import and Plaid rows is most of the work and is non-negotiable — retroactive bulk apply silently rewrites historical spending totals otherwise.

**Riskiest assumption** — That the delta over shipped learn-from-edits justifies L: imports.rs (:481-505, :579-590) already auto-applies fixed categories by merchant_key on re-import.

**Joy rationale** — The app visibly learns; each correction becomes a permanent investment instead of repeated toil.

**Skeptic's challenge** — The prior-art scan missed shipped learn-from-edits, so the emotionally-resonant core ("fix once, comes back fixed") already partially exists and the true delta is narrower than pitched; framing corrected from "new" to "extension." Kept over that objection because the remainder — explicit conditions, rename rules, dry-run, retroactive apply, Plaid coverage, and rule management — is precisely what the household touches weekly, and severity 5 stands.

### 3. Bills calendar + short-horizon projected-balance forecast — extension of the recurring MVP

**Problem** — Recurring detection says what happened; nothing shows what's about to hit or whether an account goes low before payday. The 1–90-day horizon between recurring detection and FIRE projections (projections.rs is yearly-horizon only) is empty.

**Demand evidence** — Strong, verified to the digit via GitHub API: https://github.com/actualbudget/actual/issues/517 (139 +1s), https://github.com/actualbudget/actual/issues/1534 (87), https://github.com/actualbudget/actual/issues/1928 (64, with the verbatim Dec 22 2025 comment "I tested Monarch Money and they had this feature, it was very useful"), https://github.com/actualbudget/actual/issues/4244 (48), https://github.com/firefly-iii/firefly-iii/issues/7529 (7, open). Monarch reference: https://help.monarch.com/hc/en-us/articles/4890751141908-Tracking-Recurring-Expenses-and-Bills (help-center bot-blocked to fetchers; soft corroboration only).

**Competitor landscape** — Monarch is the reference implementation (calendar + paid/late colors). Correction from skeptic review: Actual shipped an experimental Balance Forecast (merged PRs May–June 2026, feedback issue #7669), so "no self-hosted tool has a balance curve" is stale. What survives as differentiation is per-currency projection with FX-transfer prompts — structurally impossible for single-currency Actual — plus the paid/missed calendar surface.

**Proposed Patrimonio shape** — Extend api/recurring.rs's /upcoming expansion (don't rebuild); services/loan_match.rs (481 lines) is the in-repo precedent for expected→posted matching; balance_snapshots provide starting balances; calendar widget on the cash-flow tab; missed-bill alerts ride notifications.rs. Critically: manual-import MX accounts must get a distinct "pending import" state — mid-cycle, the app cannot distinguish "missed" from "not yet imported."

**Effort** — M. Driver: expected↔posted matching accuracy and the per-account balance curve.

**Riskiest assumption** — False "missed" reds destroy trust faster than no calendar; for MX accounts the problem is structural (statement-freshness), not just descriptor matching.

**Joy rationale** — A month of green checkmarks is calming; "will the rent clear?" answered in one glance turns anxiety into foresight.

**Skeptic's challenge** — The cross-border pitch is anchored on exactly the accounts where the feature is least trustworthy (stale-until-import MX accounts) — the flagship "BBVA short on the 15th" scenario ships broken unless the pending-import state is designed in from day one. Accepted and baked into the shape; kept because the demand evidence is the most rigorously verified in the pool.

### 4. Net-worth change attribution: FX vs market vs flows (recap digests + currency lens)

**Problem** — The dashboard shows the number moved; reconstructing *why* — peso, markets, spending, a sync glitch — is manual archaeology. "Was it the peso or was it me" is this household's defining recurring question.

**Demand evidence** — Thin-to-moderate, and stated as such: the strongest verified corroboration is https://worthmap.com/blog/multi-currency-net-worth-tracking (a niche product marketing an FX-impact calculator — corroborates the need, weakens the uniqueness claim). Kubera Recap exists but does NOT decompose (https://help.kubera.com/article/114-what-is-recap-in-kubera). Two researcher citations were overstated and are discounted: https://wallethacks.com/kubera-review/ does not single out Recap as claimed, and https://jeangalea.com/kubera-review/ never mentions it. MMM threads 403 (title-level only): https://forum.mrmoneymustache.com/welcome-to-the-forum/how-to-keep-track-of-net-worth-with-assets-in-different-currencies/, https://forum.mrmoneymustache.com/investor-alley/net-worth-tracking-spreadsheet-with-currency-conversion/. Evidence score adjusted 3→2 accordingly.

**Competitor landscape** — Kubera converts but can't decompose; Worthmap markets the FX-vs-performance split (SaaS); no self-hosted/OSS tool does it — the uniqueness claim is softened to that, per skeptic.

**Proposed Patrimonio shape** — New dashboard endpoint decomposing snapshot deltas per currency (balance_snapshots stores native balance + currency + balance_usd per row; exchange_rates holds the history; transactions provide flows); currency-lens toggle on net_worth_card.dart (USD / MXN / FX-held-constant); digest rides the existing notifications-bell cron precedent. Must respect the carry-forward snapshot rule — the rust-backend skill's #1 bug class lives exactly here.

**Effort** — M. Driver: attribution math that provably sums to the actual delta across carry-forward-sparse snapshots, gap-y on-demand FX history, and manual accounts that lump weeks of flows into one import day.

**Riskiest assumption** — A decomposition that doesn't sum to the observed delta, or that misattributes an import backlog as "savings," reads as a bug, not an insight.

**Joy rationale** — Highest joy on the list: the scary red month turns out to be 90% peso movement and your savings rate was fine — the chart absolves you. That emotional clarity is unique to cross-border users.

**Skeptic's challenge** — Two evidence citations overstated their sources and Worthmap contradicts "no competitor decomposes this." Both recorded; kept because the fit case never rested on external demand — the inputs are fully stored, the shipped balance-claim banners show the owner already pulls in this direction, and it is the highest-leverage unshipped insight over existing data.

### 5. Transfer + remittance fee/spread analytics (annual "cost of being cross-border" report)

**Problem** — Every USD↔MXN move costs spread and fees, and no tool ever totals what moving your own money actually cost you per year.

**Demand evidence** — Thin, and priced as thin (evidence capped at 2): https://github.com/firefly-iii/firefly-iii/issues/5265 (real, open since Nov 2021, milestoned-unimplemented — the fee-field fragment, not the report). Discounted: https://github.com/ghostfolio/ghostfolio/issues/789 (closed/fixed — met demand) and https://github.com/we-promise/sure/issues/24 (brokerage-fee input, different shape). Nobody has asked for the aggregate report itself; for a single-family self-hosted product, owner utility on shipped machinery carries it.

**Competitor landscape** — Wise shows per-transfer fees only inside Wise; Firefly's ask is 4+ years unaddressed; no aggregator answers the annual question.

**Proposed Patrimonio shape** — Aggregation endpoint summing implied-vs-spot deltas per year/provider over cash_fx_transfers (implied_fx_rate NUMERIC(20,8) + persisted matched_keyword already serialized by api/dashboard/fx_transfers.rs); summary section in the FX center sheet or cross_currency_transfers_card.dart. **Scoped honestly to a total-cost (spread-bundled) number** — per skeptic, the fee-vs-spread decomposition is not computable for deducted-fee providers like Wise without manual per-transfer fee entry, so the headline is "moving money cost you ~$X vs mid-market," with an optional manual fee field as follow-up.

**Effort** — S. Best cost/moat ratio on the list; zero new data for the core.

**Riskiest assumption** — Small per-transfer deltas are noisy (spot is a ±7-day-nearest mid-market rate) and provider grouping has an "unknown" bucket for keywordless links.

**Joy rationale** — A number nobody has ever seen about themselves — slightly outrageous, instantly actionable, very shareable.

**Skeptic's challenge** — The pitch's "$412 total — $310 of it was spread" split cannot be produced from existing data. Accepted: the shape above drops the decomposition claim rather than shipping a fabricated split.

### 6. Guided statement reconciliation at import — extend-backlog

**Problem** — Manually-imported MX accounts drift from reality, and there is no ritual to true an account against a statement's closing balance and mark history verified. Extends NEXT.md's standing "statement-import validation + balance-anchored dedup hash" line with real demand evidence.

**Demand evidence** — Moderate, all links live and on-topic: https://support.ynab.com/en_us/reconciling-accounts-a-guide-BJFE3fHys, https://support.ynab.com/en_us/getting-started-with-reconciling-accounts-an-overview-Sy3JWx4Js, and independent coach-ecosystem corroboration https://peaceofmindspending.com/why-its-important-to-reconcile-and-how-to-do-it/ (Mar 2024) — reconciliation as a beloved ritual, not overhead.

**Competitor landscape** — YNAB is the only mainstream app that made reconciliation celebrated; Monarch/Copilot hide drift behind sync; nobody built it for statement-file imports — the exact problem Plaid-only apps structurally don't have.

**Proposed Patrimonio shape** — Upgrade continuity.rs from advisory to interactive at confirm time; per-import closing-balance assert; mismatch walkthrough; additive reconciled-through marker per account (advisory, not a hard lock — a hard lock collides with planned dedup merges). 15+ parsers already emit balance_after; the stored SALDO column (migration 2026060102) is the data half, already built.

**Effort** — M, honestly trending L: a real assert needs the statement's independently-declared SALDO FINAL, which parsers currently treat as a block-terminator token and discard (banorte_layout.rs:50, banamex_pdf.rs:152, cetes_pdf.rs:80) — capturing it touches every layout parser.

**Riskiest assumption** — Self-referentiality: deriving "closing" from the last imported row's balance_after means a parser that silently drops trailing rows still "matches to the centavo."

**Joy rationale** — The moment the computed balance matches the statement to the centavo and the account goes green is a small, repeatable win — trusting your numbers is the emotional payoff of the whole system.

**Skeptic's challenge** — The SALDO FINAL capture gap (above) pushes effort toward L, and the "locked" marker degrades to advisory — only one notch above what continuity.rs ships. Accepted into the effort estimate; kept because statement imports are the MX backbone and this is the product's center of gravity.

### 7. Sub-5-second mobile quick-entry capture

**Problem** — Logging a cash OXXO purchase takes long enough that entries get batched "for later" and never happen, corroding the data completeness the whole tracker depends on.

**Demand evidence** — Strong, verified: https://github.com/cioraneanu/firefly-pico (955★ companion app existing solely for effortless entry), https://github.com/dreautall/waterfly-iii (684★, second independent companion), https://github.com/actualbudget/actual/issues/604 (64 👍, closed-completed — competitors treat mobile entry as table stakes), https://github.com/actualbudget/actual/issues/1511 (63 👍, smarter capture).

**Competitor landscape** — Firefly's ecosystem grew two entire companion apps because the main app's entry is slow; YNAB's quick-entry is a retention pillar; Ghostfolio/Kubera don't do transactions.

**Proposed Patrimonio shape** — Polish on a shipped flow: smart defaults in openAddTransactionPanel (last-used account, MXN default, payee suggestions from own history), Android app-shortcut/launch-to-capture path (small platform-channel work). Backend untouched. Verify cold-start against the 5-second budget before committing to home-widget work.

**Effort** — M. Driver: launch path + platform channel; the risk item below could push it.

**Riskiest assumption** — Connectivity, sharper than cold-start: account list, suggestions, and the POST all round-trip to a self-hosted server from street cellular; one dead link at the OXXO and the flow degrades into exactly the failure it exists to kill. An offline queue fixes it but expands scope beyond M — no offline/queue groundwork exists anywhere in work/.

**Joy rationale** — Sub-5-second capture feels like flicking a note, not doing accounting; pico's stars are pure UX-delight demand.

**Skeptic's challenge** — The offline-queue gap (above) is the recorded sharpest point; kept with the explicit scoping decision that v1 may ship online-only with a measured cold-start gate, and the queue is a named follow-up rather than silent scope creep.

### 8. FX-aware Sankey cash-flow diagram

**Problem** — Totals per category exist, but no single picture shows income streams splitting into spending, saving, and cross-border transfers.

**Demand evidence** — Strong on the pattern, verified via GitHub API: https://github.com/actualbudget/actual/issues/1716 (27 +1s, shipped via PR #7220), https://github.com/actualbudget/actual/issues/1919 (83 comments, open — users actively iterating on Actual's experimental Sankey), https://github.com/firefly-iii/firefly-iii/issues/1601 (maintainer's verbatim "good idea, on the list" → "Sorry, I'm not going to build this any time soon"), https://www.monarch.com/blog/visualize-your-cash-flow-like-never-before (share-with-amounts-hidden shipped because users wanted to show it around), plus the hand-built SankeyMATIC culture (https://www.getrichslowly.org/sankey-diagrams/). Discounted: the Monarch "fan-favorite" help-doc quote is unverifiable (403) and https://github.com/xjtian/monarch-sankeymatic is a 1★ personal script.

**Competitor landscape** — Monarch does it best (web-only); Actual shipped under community pressure (single-currency); Firefly declined. Every implementation assumes one currency.

**Proposed Patrimonio shape** — New aggregation endpoint reshaping spending.rs's FX-normalized aggregations (transfer anti-joins already correct) into income→category→savings edges, with cash_fx_transfers rows rendered as an explicit FX-conversion node between the USD and MXN sides. Rendering is a hand-rolled CustomPainter — fl_chart 0.70.2 has no Sankey primitive — and must pass the 2026-08-02 chart-touch/l10n convention suites.

**Effort** — M. Driver: the painter (layout, link curves, hover, theming, responsive), not the data.

**Riskiest assumption** — The FX-node twist — the differentiator — has zero direct demand evidence; every cited thread is single-currency users. It is inferred, not requested.

**Joy rationale** — Joy 5: the one chart people screenshot and share, and a two-currency household has literally never seen its life drawn as one river.

**Skeptic's challenge** — Painter overrun risk plus the inferred-not-requested FX node, both recorded. Kept because the researcher's core claim survives: two OSS leaders independently shipped Sankeys under pressure, the data side is a reshape of shipped machinery, and this is the highest-joy artifact on the list.

## Proposed FUTURE.md additions

This is a PROPOSAL — the owner reviews and applies it to `work/FUTURE.md`; nothing has been committed.

```diff
+## User rules engine + dry-run auto-categorization (extends categorize.rs + learn-from-edits)
+
+**Status:** Proposed (feature-research sweep). Extension, not greenfield:
+curated categorize.rs (1,109 lines) and merchant_key learn-from-edits
+(imports.rs:481-505) already cover the import path; this adds explicit,
+persisted, user-defined rules with a previewable diff.
+**Tracking:** This file.
+
+### Why
+Dirty es-MX descriptors across nine MX parsers are the biggest recurring
+chore. Strongest converged external evidence in the research sweep
+(actual-ai 502★ bolt-on, Firefly HN thread, Monarch/Lunch Money rules docs).
+
+### Plan
+* `user_rules` table + CRUD; consulted before the curated engine.
+* "Save as rule" affordance in transaction_detail_panel.dart.
+* Rename actions ride the shipped cluster-rename machinery.
+* Retroactive apply gated behind a dry-run diff — the diff is the safety
+  mechanism, not polish. Cover BOTH import and Plaid (sync.rs) paths.
+
+### Acceptance
+* A rule created from a fixed Banamex row auto-applies on the next
+  statement import AND retroactively via a previewed, confirmed diff.
+* No historical totals change without an explicit confirm.
+
+---
+
+## Bills calendar + 1–90-day projected balances (extends the recurring MVP)
+
+**Status:** Proposed (feature-research sweep). Extends /api/recurring/upcoming,
+upcoming_bills_card, and loan due-pills; the missing pieces are the calendar
+surface, expected↔posted matching, and the per-account balance curve.
+**Tracking:** This file.
+
+### Why
+Verified 48–139-upvote asks across Actual/Firefly; users cite Monarch's
+calendar as a switch reason. Fills the acknowledged gap between recurring
+detection and FIRE-horizon projections.
+
+### Plan
+* Calendar widget on the cash-flow tab off /recurring/upcoming.
+* Expected→posted matching (loan_match.rs is the precedent) with
+  paid / late / missed states.
+* Per-currency projected-balance curve from balance_snapshots; FX-transfer
+  prompt ("move USD→MXN before the 15th").
+* Manual-import MX accounts get a distinct "pending import" state —
+  never render "missed" for a bill that may simply not be imported yet.
+
+### Acceptance
+* A detected CFE bill shows expected on the calendar, flips to paid when
+  the posted row matches, and never shows a false red on a stale manual
+  account.
+
+---
+
+## Net-worth change attribution: FX vs market vs flows
+
+**Status:** Proposed (feature-research sweep). All inputs stored
+(balance_snapshots native+USD per row, exchange_rates history, transactions);
+no self-hosted tool decomposes this. Evidence thin (Worthmap markets the
+SaaS equivalent); the case is internal fit.
+**Tracking:** This file.
+
+### Why
+"Was it the peso or was it me" is the household's defining recurring
+question; the 2026-08-02 balance-claim banners already do a mini version.
+
+### Plan
+* Dashboard endpoint decomposing period deltas into FX / market / flows
+  per currency; must sum exactly to the observed delta (show a residual
+  bucket rather than fudge).
+* Currency-lens toggle on the net-worth card (USD / MXN / FX-held-constant).
+* Optional weekly digest via the notifications bell (cron precedent exists).
+* Respect carry-forward snapshots and gap-y FX history — the rust-backend
+  skill's #1 bug class lives here; regression-test the sum invariant.
+
+### Acceptance
+* For any window: FX + market + flows (+ residual) == snapshot delta,
+  per currency and in USD, on seeded fixture data.
+
+---
+
+## Household continuity dossier (bilingual export; inactivity switch deferred)
+
+**Status:** Proposed (feature-research sweep). Dossier half only — no SMTP
+infra exists and the spouse already has a read_only login, so the dead-man
+switch is out of scope.
+**Tracking:** This file.
+
+### Why
+A binational estate is the worst case (FBAR inventory, CetesDirecto, two
+tax regimes); Bogleheads' "death binder" threads recur for a decade and
+Kubera productized it. Patrimonio already maintains the executor's checklist.
+
+### Plan
+* Export endpoint aggregating accounts/institutions/loans/people plus
+  owner-written instructions, rendered as printable bilingual HTML riding
+  the tax_exports.rs / loans.rs lang-toggle pattern.
+* Staleness note on the cover page ("data as of …") so the artifact is
+  honest off-server.
+
+### Acceptance
+* One click yields an en or es-MX printable packet listing every
+  institution/account/loan the app knows, suitable for a folder or safe.
+
+---
+
+## Annual transfer-cost report (spread analytics on cash_fx_transfers)
+
+**Status:** Proposed (feature-research sweep). S-effort aggregate over
+shipped implied-vs-spot machinery. Scoped to TOTAL cost vs mid-market —
+the fee-vs-spread split is not computable for deducted-fee providers and
+is explicitly out of scope for v1.
+**Tracking:** This file.
+
+### Why
+Nobody — including Wise — totals what moving money between the two
+countries costs per year. Demand evidence is thin (Firefly #5265 is the
+nearest ask); this ships on owner utility and moat, and that's stated.
+
+### Plan
+* Aggregation endpoint summing (implied vs spot) deltas per year and per
+  matched_keyword provider (with an "unknown" bucket for keywordless links).
+* Summary section in the FX center sheet.
+* Optional follow-up: manual per-transfer fee field, kept separate to
+  avoid double-counting against the spread delta.
+
+### Acceptance
+* FX center answers "what did moving money cost us in <year>, total and
+  by provider" with the ±7-day spot-rate caveat displayed.
```

## Appendix A — researched and rejected

- **Multi-currency envelope budgeting (quincena cycles, goal templates)** — strongest raw evidence in the sweep (331 reactions) but an XL new subsystem betting on a methodology this non-envelope household shows no sign of practicing.
- **Automatic Mexican bank sync (Belvo/Finerio-class aggregator)** — existential non-code risk: individual/self-hoster access to MX aggregator credentials is unproven; a feasibility spike, not a feature.
- **FIRE historical backtesting + milestone what-ifs** — marquee success-rate number already ships; queued mean-vs-p50 honesty fix comes first, and the MX historical series that would make it special is the unsourced hard part.
- **Debt payoff simulator (extra-payment what-ifs)** — cheap, but value wholly conditional on carrying interest-bearing debt; no evidence this FIRE-mode household does, and synced cards likely lack APR.
- **Named savings goals with FX-aware on-track projection** — shipped single net-worth-goal tile scratches most of one household's itch; virtual-allocation double-counting rules add real design cost for a modest increment.
- **Cash-buffer / liquidity-runway metric (Age of Money analogue)** — emergency-fund card already answers the core question; thin evidence and the per-currency increment is likely decorative.
- **Dual-currency + money-weighted returns** — TWR-vs-benchmark incl. the Mexican IPC already ships; IRR over reconstructed flows is numerically risky and a wrong IRR is worse than none.
- **Natural-language Q&A over own data (BYO-key/local model)** — L-effort ongoing surface for occasional questions the owner already answers via agents/SQL; a silently-wrong cross-currency sum is the house's #1 bug class.
- **Receipt/alert-email ingestion (MX bank alerts + itemized receipts)** — thin evidence for a fragile, format-churning email-parsing subsystem; parser rot and double-count risk outweigh the freshness win for now.
- **Automatic valuation feeds for real assets** — manual tracking + revaluation history already shipped; no reliable keyless US valuation API exists and the MX differentiator stays honest-manual regardless.
- **Custom report builder with pinnable dashboard widgets** — one household's dinner-table charts can ship as two or three fixed cards; a generic FX-correct query composer is a factory for the multi-currency bug class.
- **Read-only API tokens + open export** — respectability polish with near-zero cross-border relevance; direct Postgres access and the owner's session-minting workflow already cover it, and incomplete scope enforcement is a real security-regression risk.
- **OIDC / SSO login** — adoption checkbox for a public self-hosting audience; this one-family deployment uses passkeys and has no IdP in evidence.
- **MSI (meses sin intereses) installment tracking** — PM cut, overruling a skeptic survive: skeptic's own check found zero msi/meses/diferido rows in the data-rich local dev DB and no parser fixture proving MSI fragments survive import — value is fully conditional on plans the household may not run; park until prod data shows active MSI, then revisit (evidence URLs preserved in the research pool: firefly-iii#10073, actual#4959/#4481).
- **Transaction review inbox (mark-as-reviewed triage)** — PM cut agreeing with the skeptic's demotion: 2 of 4 citations didn't support their claims (Copilot pages), shipped since-visit machinery covers much of "what changed," and the real remainder belongs inside Phase 13's open "category review/correction workflow," not a standalone inbox; also collides with the shipped R-rename shortcut.
- **FX transfer-timing context (percentile framing)** — PM cut, overruling a skeptic survive: the headline "better than 87% of the past year" is uncomputable from ~2–4 months of self-recorded rates and the free feed has no historical endpoint; revisit after a year of rate history accumulates or a backfill source is chosen.
- **Plan-vs-actual projection journal** — PM cut, overruling a skeptic survive: one of two evidence links (HN 42450913) contains nothing supporting the retention claim, and the FX-attribution hook that carried its cross-border score requires per-plan baseline capture the "mostly plumbing" pitch omitted; the bare overlay MVP is a fixed chart without demand.
- **Receipt/document attachments on transactions (CFDI/factura-aware)** — dropped at triage without a recorded reason (191 +1s on actual#530 is real demand); noting here so it isn't re-researched blind: it needs new blob-storage + upload infrastructure, but it is the strongest of the cut ideas and a legitimate future candidate alongside the tax module.

---

## Appendix B — competitor inventory: mainstream connected-account trackers

# Mainstream connected-account trackers — delight vs. checkbox inventory

Method note: features inventoried from vendor help centers, changelogs, and launch posts; user sentiment cross-checked against Hacker News threads, long-term reviewer write-ups, and community-built tooling (which I treat as the strongest revealed-demand signal). Reddit is not directly crawlable by my tooling, so Reddit sentiment is cited only via secondary summaries and labeled as such. Where evidence is vendor-only, I say so.

## Monarch Money

**Delight features (evidence-backed):**
- **Sankey cash-flow diagram** — Monarch's own help center calls it "the fan-favorite Sankey diagram" ([Cash Flow help](https://help.monarch.com/hc/en-us/articles/20504904768020-Cash-Flow)); the [launch post](https://www.monarch.com/blog/visualize-your-cash-flow-like-never-before) added share-with-amounts-hidden because people wanted to show it off. Community tooling like [monarch-sankeymatic](https://github.com/xjtian/monarch-sankeymatic) predates/supplements it — people build Sankeys by hand when apps won't. Web-only.
- **Recurring calendar ("Upcoming")** — calendar+list with green-check paid / yellow different-amount / red missed states ([help](https://help.monarch.com/hc/en-us/articles/4890751141908-Tracking-Recurring-Expenses-and-Bills)), extended by [Bill Sync](https://www.monarch.com/blog/introducing-bill-sync) (statement balances + minimum dues on the calendar).
- **Rules engine** — matches original statement text/merchant/amount; renames, recategorizes, tags, hides; every manual edit offers "save as rule" ([Transaction Rules help](https://help.monarch.com/hc/en-us/articles/360048393372-Transaction-Rules)).
- **AI assistant (2026)** — answers spend questions with underlying transactions surfaced ([About Monarch's AI Features](https://help.monarch.com/hc/en-us/articles/16116906962452-About-Monarch-s-AI-Features)); a [4-year daily-use review](https://marriagekidsandmoney.com/monarch-money-review/) calls it "surprisingly helpful" for real decisions. Positive but reviewer-site-heavy evidence.
- **Household/couples sharing at no extra cost** — repeatedly cited as the #1 differentiator in post-Mint migration commentary ([Reddit-summary source, secondhand](https://www.aitooldiscovery.com/guides/monarch-money-reddit); [Rob Berger review](https://robberger.com/monarch-money-review/)). Patrimonio already has multi-user households, so noted for completeness.
- **Goals 3.0** — save-up vs pay-down split, on-track/off-track from balances + planned contributions, live projected-completion ([Goals 3.0 help](https://help.monarch.com/hc/en-us/articles/44373110771860-Introducing-Goals-3-0), [blog](https://www.monarch.com/blog/goals)); [Experian's review](https://www.experian.com/blogs/ask-experian/monarch-money-review/) highlights the virtual-allocation model (money never moves, it's labeled).

**Checkbox features (present, nobody celebrates):** flex/fixed budgets, reports, net-worth dashboard (expected post-Mint table stakes), investment tracking (present but commonly described as shallow in reviews — [Rob Berger](https://robberger.com/monarch-money-review/)). Persistent complaint theme: bank-sync glitches, same as every aggregator.

**Multi-currency / cross-border: effectively none.** Officially US + Canada only; each account displays with a bare `$`, no conversion — a 1,000 JPY transaction renders as "$1,000" ([International Accounts and Currency help](https://help.monarch.com/hc/en-us/articles/360048393552-International-Accounts-and-Currency); [third-party analysis](https://budgero.app/monarch-money-multi-currency)). Monarch's official guidance is to avoid mixing currencies. For a US+MX household, Monarch is unusable beyond the US half. That absence is the moat Patrimonio sits in.

## Copilot Money

**Delight features (evidence-backed):**
- **Design/native polish** — 2024 Apple Design Award finalist ([Apple newsroom](https://www.apple.com/newsroom/2024/06/apple-announces-winners-of-the-2024-apple-design-awards/), [Copilot's announcement](https://x.com/copilotmoney/status/1795512124678209795)); ~4.8/5 on the [App Store](https://apps.apple.com/us/app/copilot-track-budget-money/id1447330651); [Money with Katie's long-term review](https://moneywithkatie.com/copilot-review-a-budgeting-app-that-finally-gets-it-right/) praises the "stellar UI," haptics, and custom category names/colors/emojis as friction-removers.
- **The review inbox** — dashboard leads with "To Review" of unreviewed imports ([Dashboard FAQ](https://help.copilot.money/en/articles/10238054-dashboard-faq)); `R` shortcut and bulk mark-as-reviewed ([Transactions tab](https://help.copilot.money/en/articles/9554412-transactions-tab-overview)). This triage loop *is* the product's daily habit.
- **ML categorization that learns from corrections** — "freakishly spot-on" per the same 7,100-transaction reviewer.
- **Amazon itemization** — imports itemized orders, auto-matches to transactions (amount match, ±2 days), enables item-level splits ([Amazon Integration help](https://help.copilot.money/en/articles/5569639-amazon-integration)). iOS/iPad/Mac only, not web.
- **Venmo via receipt-email forwarding** — including `#copilot` + category-emoji in the Venmo note as a categorization channel ([Venmo FAQ](https://help.copilot.money/en/articles/3971255-venmo-integration-faq)).

**Checkbox features:** budgets, net worth, recurring detection (well-executed but not what reviewers dwell on), the newer [web app](https://help.copilot.money/en/articles/11780342-copilot-money-for-web) (still missing Amazon/Venmo management — the delight features are platform-locked).

**Multi-currency / cross-border: none.** USD only; foreign-currency transactions are shown at whatever USD amount the provider reports, with no conversion logic ([International Currency help](https://help.copilot.money/en/articles/10715424-international-currency)); US institutions and US App Store only, with a vote-for-your-country waitlist. Apple-ecosystem-only compounds it for a Flutter-web/Android household.

## YNAB

**Delight features (evidence-backed):**
- **The methodology itself** — zero-based "give every dollar a job"; the durable fandom is about the method more than any single feature; heavy marketing claims (92% less stressed, $600 saved first month) are vendor numbers ([features page](https://www.ynab.com/features)) — treat as marketing.
- **Reconciliation as ritual** — guided flow to true accounts against real balances and lock cleared history ([guide](https://support.ynab.com/en_us/reconciling-accounts-a-guide-BJFE3fHys), [overview](https://support.ynab.com/en_us/getting-started-with-reconciling-accounts-an-overview-Sy3JWx4Js)); the coaching ecosystem independently frames weekly reconciliation as the trust-building habit ([example](https://peaceofmindspending.com/why-its-important-to-reconcile-and-how-to-do-it/)).
- **Age of Money** — average days between earning and spending, permanently displayed ([support doc](https://support.ynab.com/en_us/age-of-money-H1ZS84W1s), [blog](https://www.ynab.com/blog/what-is-the-ideal-age-of-money)). Honest read: adored by a subset, dismissed as a gimmick by others; my direct-user-sentiment evidence here is thin (coaching blogs, vendor content).
- **Loan Planner** — payoff simulator with interest-saved deltas and a burndown chart ([launch post](https://www.ynab.com/blog/ynab-loan-planner), [debt-management page](https://www.ynab.com/features/debt-management)); generates user testimonials (e.g., ["Erin saved $40,000 of interest"](https://www.youtube.com/watch?v=jTlQIxeikhM)).

**Checkbox features:** reports/"Reflect" (weak vs Monarch), bank import (a chronic grumble historically), sharing with up to 6 people, targets (powerful but inseparable from the envelope method).

**Multi-currency / cross-border: explicitly unsupported; the workaround economy proves the demand.** One currency per budget; YNAB's official answer to multi-currency life is *maintain separate budgets per currency* ([official guide](https://support.ynab.com/en_us/using-multiple-currencies-in-ynab-a-guide-SyBF6PHno), [YNAB's digital-nomad blog](https://www.ynab.com/blog/the-digital-nomads-guide-to-budgeting-in-different-currencies)). Third parties sell gap-fillers like [Foreign Currency Accounts for YNAB](https://borsboom.io/foreign-currency-accounts-for-ynab/), and in Lunch Money's Show HN a commenter described two-currency YNAB life as "REALLY tough to balance" ([HN thread](https://news.ycombinator.com/item?id=20811287)). A US+MX household in YNAB means two disconnected budgets and no combined net worth — exactly the pain Patrimonio exists to kill.

## Lunch Money

**Delight features (evidence-backed):**
- **Native multi-currency** — the founding differentiator: [Show HN (Aug 2019, 229 points / 132 comments)](https://news.ycombinator.com/item?id=20811287) drew comments like "I tried apps where the only currency available was USD, they did not stick around," with praise for storing every transaction in its original currency and converting on demand. Today: 160+ currencies, one switchable primary currency, daily historic FX rates applied per transaction date ([multicurrency doc](https://support.lunchmoney.app/settings/multicurrency)).
- **Developer API + plugin community** — public API ([docs](https://support.lunchmoney.app/miscellaneous/developer-api), [lunchmoney.dev](https://github.com/lunch-money/developers), [developers page](https://lunchmoney.app/developers)); the telling detail from the [API beta announcement](https://www.indiehackers.com/product/lunch-money/our-developer-api-is-in-public-beta--M3WmiBqCFHbaL9JyceA): of the first four open-source plugins, **three synced financial institutions outside the US/Canada** — the community immediately used the API to solve cross-border sync.
- **Community-built enrichment** — ["Email to Lunch Money"](https://lunchmoney.app/blog/2026-04-14-community-newsletter) (April 2026 newsletter): a user's self-hosted Gmail→receipt-parsing pipeline that itemizes Amazon/Uber/Apple/Steam purchases into transaction splits.
- **Rules + auto-created rules** — rules apply to synced *and* CSV/PDF-imported transactions ([rules doc](https://support.lunchmoney.app/setup/rules)); by default, manual category fixes auto-create future rules ([auto-categorization doc](https://support.lunchmoney.app/setup/categories/auto-categorization)).
- **Unreviewed-transaction status** — same triage pattern as Copilot, rule-integrated ([transaction status doc](https://support.lunchmoney.app/finances/transactions/transaction-status)).
- **Solo-dev transparency/personality** — recurring HN goodwill ([2020 congratulation thread](https://news.ycombinator.com/item?id=22507278); [2025 recommendation](https://news.ycombinator.com/item?id=42603413) — content behind a rate-limit when I fetched, engagement unverified; [Product Hunt reviews](https://www.producthunt.com/products/lunch-money/reviews)). Not portable as a feature, but it shows an audience that rewards openness — a self-hosted project's natural crowd.

**Checkbox features:** budgets, recurring items, net worth, crypto tracking (Patrimonio already covers crypto via Coinbase/Bitso), CSV/PDF import (good, and notable that rules integrate with it).

**Multi-currency / cross-border: the standard-setter among the four — but broad, not deep.** Original-currency storage + daily historical rates + switchable primary currency is exactly right ([doc](https://support.lunchmoney.app/settings/multicurrency)). What it does *not* have (per docs; no claims found): FX-aware investment lots, realized-gain accounting across currencies, implied-rate-vs-spot comparison on cross-currency transfers, or any US/MX tax awareness — all places where Patrimonio is already ahead. The envy runs the other way only on breadth (160 currencies) and on the plugin ecosystem that lets users self-serve non-US bank sync.

## Cross-app synthesis for Patrimonio

1. Two independently loved apps (Copilot, Lunch Money) converged on the same **review-inbox** pattern, and three of four have a **rules engine** — these are the safest high-delight bets and both compound the value of Patrimonio's MX statement-import pipeline.
2. The strongest *cross-border-native* opportunities aren't in any competitor: **per-import reconciliation** (YNAB's ritual applied to statement files) and **MX bank alert-email parsing** (Copilot's Venmo-email trick generalized to Banamex/BBVA real-time alerts).
3. Monarch proves visual, shareable artifacts (**Sankey**, color-coded **bill calendar**) drive affection; a two-currency Sankey would be a genuinely novel artifact no app on the market can draw.
4. On multi-currency, the field is Lunch Money and then nobody: Monarch renders yen as dollars, Copilot is USD-only, YNAB tells users to keep two sets of books. Patrimonio's USD/MXN depth already exceeds Lunch Money's breadth-first model; the gap to steal is Lunch Money's *primary-currency toggle everywhere* ergonomics and its API-enabled community sync story.

## Appendix C — competitor inventory: wealth/planning + self-hosted set

# Competitor notes — wealth/planning + self-hosted/OSS slice

Method: primary sources (sites, docs, READMEs) cross-checked against HN threads and GitHub issue reactions (Reddit is crawl-blocked for our agent; Reddit sentiment below comes via secondary summaries and is labeled). Engagement figures are as-of 2026-08-03.

## Kubera (paid SaaS, ~$150+/yr)

**Delight features (evidenced):**
- **Dead Man's Switch** — inactivity-triggered secure handoff of the full portfolio to beneficiaries. Called out as "a standout feature" in independent reviews ([WallStreetZen review](https://www.wallstreetzen.com/blog/kubera-app-review/), [wallethacks](https://wallethacks.com/kubera-review/)); this is the feature reviewers mention unprompted.
- **Recap** — historical reports of net worth/allocation change over any time frame, plus an annual "wealth report" ([help.kubera.com Recap article](https://help.kubera.com/article/114-what-is-recap-in-kubera)). Reviewers cite it as what makes checking Kubera pleasant rather than a chore ([jeangalea.com review](https://jeangalea.com/kubera-review/)).
- **Connect-anything breadth** — DeFi/staking/NFT wallets, Carta LP positions with capital calls + IRR, AI-assisted valuations for homes/cars/watches ([kubera.com](https://www.kubera.com/)). r/fatFIRE users (via [WallStreetZen's roundup](https://www.wallstreetzen.com/blog/kubera-app-review/)) report it "saves at least 10 hours a year" — secondary source, labeled as such.

**Checkbox features:** advisor sharing, "Club Benchmarks" peer comparison (privacy-adjacent gimmick), document attachment. Main complaint everywhere: price.

**Multi-currency / cross-border:** genuinely first-class — assets tracked in native currencies, net worth viewable in any currency (even BTC); marketed explicitly at "wealth across borders" ([kubera.com](https://www.kubera.com/)). But: no tax layer at all, no FX-transfer analysis, no MX-specific anything. Kubera is the aspirational UX bar for a cross-border tracker, minus taxes and self-hosting.

## ProjectionLab (paid SaaS, $800 lifetime/self-host tier)

**Delight features (evidenced):**
- **Interactive plan canvas** — drag milestones and watch the projection react live; "simple" yet "extremely powerful" per the [30k-MAU bootstrap HN thread](https://news.ycombinator.com/item?id=42450913); repeat evangelists across years of HN threads ([2023 Show HN](https://news.ycombinator.com/item?id=36849502), [returning fan comment](https://news.ycombinator.com/item?id=36851240)).
- **Monte Carlo + historical backtesting** with a headline "chance of success," per-year drill-down tables ([projectionlab.com](https://projectionlab.com/)).
- **Plan-vs-actual journaling** — "journal and visualize your actual progress over time and compare against your initial projections" ([projectionlab.com](https://projectionlab.com/)).
- **No account linking** is framed and *praised* as a feature (privacy) ([HN](https://news.ycombinator.com/item?id=36852063)).

**Checkbox:** multiple country tax presets (US detail is deep — IRMAA cliffs, ACA limits; CA/UK/AU/DE/NL are shallower).

**Multi-currency / cross-border:** tax presets for 6 countries but **no mid-plan country switching** — HN users retiring across borders (US 401(k) + UK residence) explicitly asked for switching tax presets at a milestone and were told it's not there ([HN thread](https://news.ycombinator.com/item?id=42450913), ~2 comments). No US+MX preset pair. This is the gap a US+MX tracker can own: modeling "move to MX in 2031" is exactly what ProjectionLab can't do.

## Actual Budget (OSS, 27.9k★)

**Delight features (evidenced):**
- **Local-first speed + data ownership** — the recurring theme in HN threads ([open-sourcing thread](https://news.ycombinator.com/item?id=39276012), [origin Show HN](https://news.ycombinator.com/item?id=19027064)).
- **Goal templates / budget automation** — declarative `#template` notes that fill the whole month's budget in one click; the project itself brags they're "more flexible than YNAB's targets" ([docs](https://actualbudget.org/docs/experimental/goal-templates/), [blog](https://actualbudget.org/blog/2023-12-15-automate-your-budget-with-goal-templates/)).
- **Custom reports + Sankey** — shipped because of massive user pressure: [Custom Reports #730](https://github.com/actualbudget/actual/issues/730) (163 👍), [Sankey diagram #1716](https://github.com/actualbudget/actual/issues/1716) (27 👍).
- Rules engine; community companion **actual-ai** (AI categorization, [502★](https://github.com/sakowicz/actual-ai)) and the SimpleFIN bridge ecosystem ($1/mo US bank sync praised on [HN](https://news.ycombinator.com/item?id=42605163)).

**Checkbox:** dark mode, tags, reconciliation locks (all top-voted, all shipped, none celebrated after shipping).

**Multi-currency / cross-border:** **none — single-currency by design.** Requests are perennial and closed: [#2147](https://github.com/actualbudget/actual/issues/2147) (16 👍, closed), [#3351](https://github.com/actualbudget/actual/issues/3351), plus multiple community PRs stuck at "[DO NOT MERGE](https://github.com/actualbudget/actual/pull/8187)". The most-loved OSS budgeter simply exiles cross-border users — that absence is Patrimonio's moat on the budgeting side.

## Firefly III (OSS)

**Delight features (evidenced):**
- **True multi-currency** — "Firefly III is 100% multi-currency. Even budgets, bills, anything" ([HN 2024 thread](https://news.ycombinator.com/item?id=39392428)); users say they chose it for this.
- **Rules/automation** — "takes a lot of clicks to set up... but once it's done things happen automatically" ([same thread](https://news.ycombinator.com/item?id=39392428)).
- **API-first design** that spawned a companion ecosystem — this is the demand map: [data-importer](https://github.com/firefly-iii/data-importer) (814★), [firefly-pico](https://github.com/cioraneanu/firefly-pico) (955★ — literally described as "a **delightful** companion for **effortless transaction tracking**"), [waterfly-iii](https://github.com/dreautall/waterfly-iii) Android app (684★), [firefly-plaid-connector-2](https://github.com/dvankley/firefly-plaid-connector-2) (144★), [firefly-iii-ai-categorize](https://github.com/bahuma20/firefly-iii-ai-categorize) (220★). Community keeps building: quick mobile entry, US bank sync, AI categorization = the three unmet demands.

**Complaints:** no native bank sync; opinionated refund/transfer accounting that "violates standard double-entry" for some ([HN](https://news.ycombinator.com/item?id=39392428)); dated UI (firefly-pico exists because of it).

**Multi-currency / cross-border:** strongest of the OSS set, but no FX-transfer intelligence: [Money Transfer Fees #5265](https://github.com/firefly-iii/firefly-iii/issues/5265) (13 👍, open) and [merge two transactions into a transfer #5675](https://github.com/firefly-iii/firefly-iii/issues/5675) (10 👍) show users hand-assembling what Patrimonio's Wise-style linking already does. US import demand visible in [Teller.io request #8598](https://github.com/firefly-iii/firefly-iii/issues/8598) (15 👍).

## Ghostfolio (OSS)

**Delight features (evidenced):**
- **Privacy/self-hosting itself** — "I hate giving my data to a third party" is the top sentiment in the [HN thread](https://news.ycombinator.com/item?id=37337482).
- **X-ray / allocation analysis + benchmark comparison** — look-through exposure, concentration risks, compare vs indices ([xda-developers hands-on](https://www.xda-developers.com/this-self-hosted-app-changed-the-way-track-investments/), [changelog](https://ghostfol.io/en/about/changelog)).

**Complaints (same HN thread):** onboarding "non-existent"; real estate/unlisted assets hard; manual stock splits; users drift back to [Portfolio Performance](https://news.ycombinator.com/item?id=37340091) or spreadsheets; data-provider fragility dominates the tracker's own issue list (Yahoo "crumb" failures: [#6118](https://github.com/ghostfolio/ghostfolio/issues/6118), [#5924](https://github.com/ghostfolio/ghostfolio/issues/5924)).

**Multi-currency / cross-border:** supported, but it's where Ghostfolio creaks — its top-reacted issues are currency pain: [custom-currency activities #3320](https://github.com/ghostfolio/ghostfolio/issues/3320) (20 👍), [can't edit activity currency #705](https://github.com/ghostfolio/ghostfolio/issues/705) (14 👍), [fees in a different currency #789](https://github.com/ghostfolio/ghostfolio/issues/789), [API currency mismatch #3094](https://github.com/ghostfolio/ghostfolio/issues/3094) (open). Lesson: multi-currency portfolio math earns loyalty precisely because everyone else gets it subtly wrong.

## Maybe (OSS, archived) → community fork "Sure"

- **Status:** repo [archived](https://github.com/maybe-finance/maybe) at 54.4k★, final release v0.6.0, last push 2025-07-24; company pivoted (maybefinance.com now redirects to maybe.co). Its delight was Rails-app polish + an AI assistant + Plaid-class sync in a self-hostable package.
- **The demand didn't die:** community fork [we-promise/sure](https://github.com/we-promise/sure) is at 9.3k★ and actively pushed (Aug 2026). Top fork asks: European bank providers ([#33](https://github.com/we-promise/sure/issues/33), 12 👍), broker sync ([#392](https://github.com/we-promise/sure/issues/392), 11 👍), OIDC ([#34](https://github.com/we-promise/sure/issues/34), 10 👍), pluggable AI providers ([#17](https://github.com/we-promise/sure/issues/17)).
- **Multi-currency / cross-border:** nominally multi-currency but flaky in exactly the dangerous way: open issue "[Allow adding/overriding exchange rates — and stop **silently converting at rate 1.0** when a rate is missing](https://github.com/we-promise/sure/issues/2417)" (5 👍), plus an i18n-rework request ([#1362](https://github.com/we-promise/sure/issues/1362)). Another proof point that correct FX handling is rare and load-bearing.

## Appendix D — demand landscape: OSS GitHub issues + app-store pain

## Demand-landscape notes — OSS finance-app communities + app-store pain (2026-08-03)

Method: GitHub search API sorted by `+1` reactions over Actual Budget, Firefly III, Ghostfolio, Maybe (and its community successor), plus web/app-store review sweeps for Monarch, Copilot, YNAB. Reaction counts and dates recorded as of today. Two candidate ideas were **dropped after checking Patrimonio's own code** (import dry-run preview and manual-asset valuations — both already exist in `backend/src/api/imports.rs` and `accounts.rs`).

### Maybe Finance: tracker is gone
[maybe-finance/maybe](https://github.com/maybe-finance/maybe) is archived with **issues disabled** (`has_issues: false`, 54.3k stars) — its demand history is unrecoverable via the API. The community continuation is [we-promise/sure](https://github.com/we-promise/sure), whose issue tracker I mined instead. Sure's early history is itself a demand signal: the first issues filed post-fork were **OIDC SSO** ([#34](https://github.com/we-promise/sure/issues/34), 10 +1), **API docs** ([#20](https://github.com/we-promise/sure/issues/20), 5 +1), **transaction attachments** ([#39](https://github.com/we-promise/sure/issues/39)), **apply-all-rules** ([#11](https://github.com/we-promise/sure/issues/11)), and **BYO-LLM providers** ([#17](https://github.com/we-promise/sure/issues/17), [#178](https://github.com/we-promise/sure/issues/178)) — a ranked list of what self-hosters missed most. Notable FX signal: [#2417](https://github.com/we-promise/sure/issues/2417) "stop silently converting at rate 1.0 when a rate is missing" (5 +1, Jun 2026) — silent-FX-fallback bugs actively burn multi-currency users elsewhere; Patrimonio's first-class FX is the moat.

### Actual Budget — the richest vein
Actual bulk-closed its pre-2023 feature backlog on 2023-05-01 ("completed" state_reason, but unshipped) — yet users **kept commenting for years**, which makes those threads unusually honest demand records:

- [#1132 Budget/category currencies — 331 +1](https://github.com/actualbudget/actual/issues/1132): the largest signal in this entire sweep. Active comments through Nov 2024; users name **Lunch Money** as the only tool doing multi-currency budgets well. Actual remains single-currency.
- [#530 Transaction attachments — 191 +1](https://github.com/actualbudget/actual/issues/530): new "I came in hoping this existed" comment **May 2026**; ≥6 duplicate filings ([#1818](https://github.com/actualbudget/actual/issues/1818), [#2275](https://github.com/actualbudget/actual/issues/2275), [#3628](https://github.com/actualbudget/actual/issues/3628) 13 +1, [#4782](https://github.com/actualbudget/actual/issues/4782), [#5668](https://github.com/actualbudget/actual/issues/5668), [#8575](https://github.com/actualbudget/actual/issues/8575)).
- Forecasting cluster: [#517 projected balances — 139 +1](https://github.com/actualbudget/actual/issues/517), [#1534 upcoming txns in budget — 87](https://github.com/actualbudget/actual/issues/1534), [#1928 calendar view — 64](https://github.com/actualbudget/actual/issues/1928) (Dec 2025 comment praises **Monarch's** calendar by name), [#4244 running-balance forecast — 48](https://github.com/actualbudget/actual/issues/4244).
- [#975 change first-day-of-month — 102 +1](https://github.com/actualbudget/actual/issues/975) + [#5849 Pay Periods — 16 +1](https://github.com/actualbudget/actual/issues/5849), where a community member is building it with a live preview (Oct 2025). Non-calendar-month budgeting is chronically underserved → quincena angle.
- Custom reports: [#730 — 163 +1](https://github.com/actualbudget/actual/issues/730) shipped as widgets; the [feedback thread #1918 has 176 comments](https://github.com/actualbudget/actual/issues/1918) and spawned follow-on widget asks ([#5633](https://github.com/actualbudget/actual/issues/5633) 9 +1, [#4589](https://github.com/actualbudget/actual/issues/4589) 12 +1). Post-ship engagement this high = the feature compounds.
- Sankey: [#1716 — 27 +1, implemented ~Apr 2026](https://github.com/actualbudget/actual/issues/1716); [feedback thread #1919 still open, 83 comments](https://github.com/actualbudget/actual/issues/1919). Contrast: Firefly's maintainer **declined** it ("Sorry, I'm not going to build this any time soon" — [#1601](https://github.com/firefly-iii/firefly-iii/issues/1601)).
- Rules: [#3606 rule-action templating — 12 +1, 67 comments, open](https://github.com/actualbudget/actual/issues/3606); comments show regex pain, no dry-run, and a user parsing "installment 01/03" strings — a bridge to the MSI candidate.
- Other historic top asks (context, mostly covered by Patrimonio already or shipped since): subcategories [#1320 — 316](https://github.com/actualbudget/actual/issues/1320), multi-user [#524 — 315](https://github.com/actualbudget/actual/issues/524), Plaid [#898 — 317](https://github.com/actualbudget/actual/issues/898), account groups [#1683 — 143](https://github.com/actualbudget/actual/issues/1683).

### Firefly III
- Top-reacted **open** issue: [OIDC support #10662 — 32 +1 (Jul 2025)](https://github.com/firefly-iii/firefly-iii/issues/10662), maintainer "It's on the list!", unshipped.
- [Money transfer fees #5265 — 13 +1, open since 2021](https://github.com/firefly-iii/firefly-iii/issues/5265): the asker's workaround (manual second withdrawal) is what every cross-border user does today.
- [MSI installments #10073 — 9 +1, open, no maintainer action](https://github.com/firefly-iii/firefly-iii/issues/10073); same ask closed-unshipped twice in Actual ([#4959 — 12](https://github.com/actualbudget/actual/issues/4959), [#4481 — 9](https://github.com/actualbudget/actual/issues/4481)). Three independent communities → real recurrence, LATAM-flavored.
- [Data-import dry-run #8687 — 10 +1](https://github.com/firefly-iii/firefly-iii/issues/8687): validated pain, but **Patrimonio already has an import preview with duplicate detection** — worth noting as a strength, not a candidate.
- Bank-connectivity asks dominate the rest ([SimpleFIN #5396 — 28](https://github.com/firefly-iii/firefly-iii/issues/5396), [Enable Banking #10753 — 15](https://github.com/firefly-iii/firefly-iii/issues/10753), [Teller #8598 — 15](https://github.com/firefly-iii/firefly-iii/issues/8598)) — sync breadth is the perpetual #1 want in every community.

### Ghostfolio
Top asks are mostly multi-currency correctness — [activity in custom currency #3320 — 20 +1](https://github.com/ghostfolio/ghostfolio/issues/3320), [can't edit activity currency #705 — 14](https://github.com/ghostfolio/ghostfolio/issues/705), [wrong exchange rate #2449 — 10](https://github.com/ghostfolio/ghostfolio/issues/2449), [fees in a different currency #789 — 4](https://github.com/ghostfolio/ghostfolio/issues/789) — plus [unlisted securities #1352 — 14, since implemented](https://github.com/ghostfolio/ghostfolio/issues/1352). Reading: portfolio users' loudest pain is FX correctness, which Patrimonio treats as first-class; the fee-currency ask feeds the transfer-fee candidate.

### App-store pain — Monarch / Copilot / YNAB
- **YNAB** ([4.8★, 61K ratings on the App Store](https://apps.apple.com/us/app/ynab/id1010865877?see-all=reviews)): critical reviews center on sync lag ("maybe by the third day"), UI churn ("slow down with the user interface updates"), and credit-card handling ("not intuitive"). The structural gap is single-currency budgets — [a 2026 expat review](https://borderlessbudget.com/blog/ynab-for-expats-review) concludes "YNAB wasn't built for that situation" for earn-in-X-spend-in-Y users.
- **Monarch** ([4.9★/70K iOS, 4.7★/17.6K Play per Forbes](https://www.forbes.com/advisor/banking/monarch-budget-app-review/)): complaints cluster on Plaid sync for smaller institutions, the $99.99/yr price for single users, weak investment analysis, and [lack of per-account privacy controls between partners](https://www.aitooldiscovery.com/guides/monarch-money-reddit) — a household-permissions gap adjacent to Patrimonio's multi-user module. Its bill calendar and Sankey are the delight features competitors' users cite by name.
- **Copilot** ([Forbes review](https://www.forbes.com/advisor/banking/copilot-budget-app-review/), [FinCompareLab](https://www.fincomparelab.com/reviews/copilot-money-review/)): biggest complaint is **no Android at all** (web app since Dec 2025 is limited) — Patrimonio's Flutter web + APK already answers this; second is data liberation: no export of a filtered view, forcing full-history spreadsheet round-trips.

### Delight vs. checkbox pattern across all sources
Checkbox asks (sync providers, OIDC, QIF import) decide *adoption*; the features people evangelize in threads are visual/insight ones: Monarch's calendar and Sankey, Actual's custom-report widgets (176-comment feedback thread). The strongest openings for Patrimonio combine both: multi-currency envelope budgets (adoption + daily delight), the forecast calendar, and the FX Sankey — each impossible or declined in every mainstream and OSS tool surveyed, and each amplified rather than diluted by the US+MX focus.

## Appendix E — demand landscape: Reddit, expat communities, forums

## Demand-landscape notes — community forums (user-voice-researcher)

**Method & coverage caveats.** Reddit (r/ynab, r/personalfinance, r/fire, r/MexicoExpats, r/ExpatFIRE) is crawl-blocked for this agent's search/fetch stack — the search API returns `reddit.com is not accessible to our user agent`, so no Reddit thread could be read or cited directly; where a Reddit phenomenon matters (the Sankey fad) it is cited via secondary documentation. Bogleheads thread pages return HTTP 402 and the MMM forum 403 on fetch, so those are cited at thread-title level from search results, which are still real, dated user asks. Hacker News (direct + [Algolia API](https://hn.algolia.com/api/v1/search?query=%22multiple%20currencies%22%20personal%20finance&tags=comment)) and GitHub (via `gh api`, for reaction counts on community feature requests) were fully readable. Evidence strength is labeled accordingly; nothing below is inflated.

### Hacker News — the self-hosted / power-user voice

- [Show HN: Lunch Money (2019)](https://news.ycombinator.com/item?id=20811287) is the richest single thread found: international users declare Plaid-only tools dead on arrival ("Without auto import I just cannot use these apps" — Aeolun), YNAB users defend the envelope method while wanting multi-currency, and the spreadsheet-era wishlist is explicit — regex categorization rules, bulk recategorize, what-if expense forecasting, non-monthly recurring cycles ("I spend $100 on public transport every 2nd Thursday" — phodge), and self-hosting as "an _absolute_ requirement" (Fiahil).
- [Ask HN: How do you record your personal finances? (2022, 44 pts / 76 comments)](https://news.ycombinator.com/item?id=31605741): forecasting future transactions across mixed cycles (johnthesecure), data-portability trauma ("burned by MS Money going away, no proprietary formats again" — howeyc), spreadsheets still winning for couples.
- ["GnuCash is right. It's also why I built my own finance app" (2025/26, 19 pts / 24 comments)](https://news.ycombinator.com/item?id=48476514): "no easy, free way to automatically pull my transaction data" (dgrin91); "a delegated read-only api key against a specific account shouldn't be that hard" (tracker1).
- Recurring HN theme across all three: **auto-import coverage, categorization rules, forecasting, and open APIs/export** are the four gaps that make this crowd fall back to spreadsheets. Multi-currency appears constantly as a qualifier ("for those of us not in the US").

### Envelope budgeting × multi-currency — the single loudest quantified signal

- [actualbudget/actual#1132 "Budget Currency and Category Currencies"](https://github.com/actualbudget/actual/issues/1132) — **331 reactions, 57 comments**, open since June 2023, plus at least seven sibling issues ([#2147](https://github.com/actualbudget/actual/issues/2147) 16 reactions, [#2947](https://github.com/actualbudget/actual/issues/2947) 13, [#2288](https://github.com/actualbudget/actual/issues/2288) 13, [#2373](https://github.com/actualbudget/actual/issues/2373) 32 for local-currency fields, [#1589](https://github.com/actualbudget/actual/issues/1589) 62 for currency symbols). The most popular self-hosted envelope budgeter's top request is exactly the intersection Patrimonio sits on.
- [YNAB's official multi-currency guide](https://support.ynab.com/en_us/using-multiple-currencies-in-ynab-a-guide-SyBF6PHno) tells users to run **separate budgets per currency** — the market leader concedes the use case.

### Bogleheads — recurrence king: the "death file"

The surviving-spouse dossier is the most recurrent tooling ask found anywhere in this sweep, spanning 15+ years: ["Actual instructions for spouse in event of death" (2012)](https://www.bogleheads.org/forum/viewtopic.php?t=103601), ["In Case of Death Document"](https://www.bogleheads.org/forum/viewtopic.php?t=188292), ["Template for financial life for spouse if I'm dead?"](https://www.bogleheads.org/forum/viewtopic.php?t=346184), ["Death Binder: Reality and Simplicity"](https://www.bogleheads.org/forum/viewtopic.php?t=409760), ["How will my family know about my assets if I drop dead?"](https://www.bogleheads.org/forum/viewtopic.php?t=468584), and the 2026 thread that names the core failure — ["does yours actually stay updated?"](https://www.bogleheads.org/forum/viewtopic.php?p=8741742). The [Bogle Center runs chapter sessions on it](https://boglecenter.net/bogleheads-chapter-series-documenting-financial-information-for-surviving-spouse-executor/). Every solution in these threads is a manually-maintained document; the pain is staleness — which a tracker that already knows every account can eliminate. Bogleheads is also the home of the [home-equity-tab net-worth spreadsheet practice](https://www.bogleheads.org/forum/viewtopic.php?t=400786) and of US-citizen-in-Mexico threads ([t=313515](https://www.bogleheads.org/forum/viewtopic.php?t=313515), [Boglehead Investing in Mexico](https://www.bogleheads.org/forum/viewtopic.php?t=407310)) where tooling is conspicuously absent from the answers (one MoneyWiz mention).

### MMM forum + expat communities — the cross-border denomination problem

- MMM: ["How to keep track of net worth with assets in different currencies?"](https://forum.mrmoneymustache.com/welcome-to-the-forum/how-to-keep-track-of-net-worth-with-assets-in-different-currencies/) and ["Net Worth Tracking Spreadsheet with Currency Conversion"](https://forum.mrmoneymustache.com/investor-alley/net-worth-tracking-spreadsheet-with-currency-conversion/) (title-level; forum blocks fetching). Niche products ([Worthmap](https://worthmap.com/blog/multi-currency-net-worth-tracking), [moneyabroad.co's expat-tracker roundup](https://www.moneyabroad.co/tool-categories/net-worth-tracking)) now market to exactly this pain — commercial corroboration.
- Expat Forum Mexico: perpetual transfer-mechanics threads — ["Best exchange rate...."](https://expatforum.com/expats/mexico-expat-forum-expats-living-mexico/530617-best-exchange-rate-2.html), ["Transferring money into Mexico"](https://www.expatforum.com/threads/transferring-money-into-mexico.88177/) — plus a content industry ([Mexperience](https://www.mexperience.com/buying-pesos-exchanging-foreign-currency-in-mexico/), [ExpatDen](https://www.expatden.com/mexico/best-way-to-send-money-to-mexico/)) answering "when/how do I move dollars to pesos". Nobody's tracker helps; Wise/XE alerts live inside transfer funnels.
- Mexico domestic market: [Finno](https://finno.mx/) (30+ MX banks + SAT sync) and [Finerio → Finerio Connect](https://blog.finerioconnect.com/open-banking-facilitara-las-finanzas-personales-en-mexico/) prove demand for MX bank aggregation; none of these products has a US side, and no US/self-hosted product has an MX side.

### Sankey / flow visualization — a fad that became table stakes

Documented Reddit-origin fad ([Get Rich Slowly on the FIRE-subreddit Sankey trend](https://www.getrichslowly.org/sankey-diagrams/)); users script exports to build them ([monarch-sankeymatic](https://github.com/xjtian/monarch-sankeymatic)); requested at [Simplifi](https://community.simplifimoney.com/discussion/5891/ability-to-visualize-my-data-using-a-sankey-diagram-edited); shipped by Monarch ([Reports docs](https://help.monarch.com/hc/en-us/articles/21846787088916-Using-Reports)), by Actual in 2026 ([83-comment feedback issue #1919](https://github.com/actualbudget/actual/issues/1919)), merged in Maybe ([PR #2269](https://github.com/maybe-finance/maybe/pull/2269)), and Firefly bundles chartjs-chart-sankey. A cash-flow product without one now reads as behind.

### What did NOT clear the bar (searched, found thin or nothing)

- **Belvo/aggregator asks in personal-finance-app communities**: HN comments mentioning Belvo are all fintech-founder shop talk ([Algolia](https://hn.algolia.com/api/v1/search?query=belvo&tags=comment)), not end-user asks — the MX-sync candidate rests on the generic auto-import demand plus MX-market product evidence.
- **Net-worth forecasting in Firefly** ([#5838](https://github.com/firefly-iii/firefly-iii/issues/5838)): 0 reactions. Kept only as corroboration for the forecast-calendar candidate, which stands on the HN quotes.
- **Zillow/property requests**: [Simplifi's](https://community.simplifimoney.com/discussion/48/add-zillow-to-track-property-value-2-merged-votes) shows 2 merged votes — weak alone; the candidate leans on [Firefly #5532](https://github.com/firefly-iii/firefly-iii/issues/5532) (20 reactions) and Mint-refugee comparisons ([Mint×Zillow 2010](https://zillow.mediaroom.com/2010-09-22-Whats-My-Home-Worth-Mint-com-Taps-Zillow-com-for-Real-Estate-Valuations)).
- **Explicit "FX rate alert in my tracker" asks**: not found anywhere — the transfer-timing candidate is honestly labeled thin despite the enormous recurrence of the underlying question.
- **Afore/INFONAVIT tracking, currency-hedged FIRE math, receipt OCR**: no citable public asks surfaced in this sweep; not proposed.

---

## Method

Produced 2026-08-03 by the `feature-research` pipeline (`.agent/workflows/feature-research.js`,
run `wf_1faaf299-d51`; team definitions in `.agent/agents/`): 4 parallel researchers
(2 competitor lenses, 2 demand lenses) → fit-and-feasibility analyst (repo-only, grep-verified
seams) → PM triage → one adversarial skeptic per shortlisted candidate → PM synthesis.
39 raw candidates → 25 after dedup/fit → 12 shortlisted →
0 skeptic kills → 8 final briefs (4 skeptic-survivors cut on PM judgment, recorded in
Appendix A). 19 agents, ~1.0M subagent tokens. The "Proposed FUTURE.md additions" section is a
PROPOSAL — nothing outside `work/research/` was modified.
