// feature-research — quarterly, READ-ONLY feature-research pipeline.
//
// Produces the material for work/research/<date>-feature-research.md: a
// PM-vetted shortlist of feature proposals grounded in (a) competitor
// research and (b) public user-demand evidence, fit-checked against the repo,
// adversarially attacked by skeptics, then synthesized into briefs. The
// workflow itself writes NOTHING — the caller assembles the report file from
// the returned sections and the owner reviews before FUTURE.md changes.
//
// Roles are maintained as .agent/agents/{competitor-analyst,
// user-voice-researcher, fit-and-feasibility-analyst, feature-skeptic,
// pm-synthesizer}.md — those are the source of truth. Workflow subagents
// cannot read .agent/agents/*, so the prompts below embed CONDENSED copies of
// each role; if a role definition changes, update both places (same
// dual-maintenance rule as quality-sweep.js).
//
// Usage: pass args = { date: "YYYY-MM-DD" } (Date.now() is unavailable in
// workflow scripts by design).

export const meta = {
  name: "feature-research",
  description:
    "Feature-research pipeline: 4 parallel researchers (competitor inventory + user-demand mining) -> repo fit/feasibility -> PM triage -> one adversarial skeptic per shortlisted candidate -> PM synthesis into briefs + proposed FUTURE.md additions. Read-only; returns report sections.",
  whenToUse:
    "Quarterly (or on demand) to refresh the feature backlog with evidence-grounded, PM-vetted proposals. Not for implementation.",
  phases: [
    { title: "Research", detail: "competitor inventory + demand mining, 4 lenses" },
    { title: "Fit", detail: "dedupe + architecture fit + effort vs the repo" },
    { title: "Triage", detail: "PM scores candidates, shortlists 8-12" },
    { title: "Skeptics", detail: "one adversarial killer per shortlisted item" },
    { title: "Synthesis", detail: "PM writes survivor briefs + FUTURE.md proposal" },
  ],
};

// args may arrive as an object or a JSON string depending on the caller —
// the 2026-08-03 run got a string and rendered "unknown-date"; parse both.
const ARGS =
  typeof args === "string" ? JSON.parse(args) : (args || {});
const DATE = ARGS.date || "unknown-date";
const REPO = "/home/nickvander/dev/patrimonio";

// ---- Shared instruction fragments -----------------------------------------

const PRODUCT =
  "Patrimonio is a self-hosted, single-family, cross-border US+Mexico " +
  "personal finance tracker: USD/MXN FX is first-class; Plaid sync for US " +
  "institutions; Coinbase/Bitso crypto; manual CSV/PDF statement imports for " +
  "MX banks (Nu, Banamex, BBVA, Santander, Banorte, HSBC, Scotiabank, " +
  "CetesDirecto, Revolut); portfolio with FX-aware lots + realized gains + " +
  "dividend income; cross-currency cash-transfer linking (Wise-style) with " +
  "implied-rate vs spot comparison; personal lending module (schedules, " +
  "interest accounting); US+MX tax planning (FBAR worksheet, Form 8949, " +
  "Schedule B, MX ISR); FIRE projections with scenario controls; recurring- " +
  "charge detection; budgets; cash-flow reporting; multi-user household via " +
  "invitations; passkeys/TOTP auth. Rust+axum+Postgres+Redis backend, " +
  "Flutter web + Android APK, localized en + es-MX.";

const PRIVACY =
  "PRIVACY (hard rule): web queries must NEVER contain the owner's name, " +
  "email, hostnames, IPs, deployment details, balances, or anything from " +
  "the repo's work/ files — search only in terms of public apps and generic " +
  "user needs.";

const CITE =
  "Cite everything: every claim carries a URL; note engagement " +
  "(upvotes/reactions/stars) and date where visible. If evidence is thin, " +
  "label it thin — never inflate. No citation -> don't assert it.";

const CANDIDATE_RULES =
  "Each candidate proposal must be something Patrimonio does not already do " +
  "(see the product description) and must carry: a one-sentence user " +
  "problem, 2-5 evidence links with notes, the competitor/tool landscape " +
  "(who does it well or fails and how), the cross-border US+MX angle (or " +
  "'none'), a joy rationale (why it delights, not just functions), and an " +
  "honest demand_strength. Return AT MOST 10 candidates — your best.";

// ---- Schemas ---------------------------------------------------------------

const RESEARCH_SCHEMA = {
  type: "object",
  properties: {
    notes_md: {
      type: "string",
      description:
        "Markdown section for the final report appendix: per-app " +
        "delight-vs-checkbox inventory with a multi-currency/cross-border " +
        "subsection per app (competitor-analyst), or the demand-landscape " +
        "notes (user-voice-researcher). Inline links throughout.",
    },
    candidates: {
      type: "array",
      maxItems: 10,
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "short feature name" },
          problem: { type: "string", description: "one-sentence user problem" },
          evidence: {
            type: "array",
            maxItems: 5,
            items: {
              type: "object",
              properties: {
                url: { type: "string" },
                note: {
                  type: "string",
                  description: "what it shows + strength (upvotes/recency)",
                },
              },
              required: ["url", "note"],
            },
          },
          landscape: {
            type: "string",
            description: "which apps/tools do it well or fail, and how",
          },
          cross_border: {
            type: "string",
            description: "US+MX / multi-currency angle, or 'none'",
          },
          joy: { type: "string", description: "why it delights, not just functions" },
          demand_strength: { type: "string", enum: ["strong", "moderate", "thin"] },
        },
        required: [
          "title", "problem", "evidence", "landscape",
          "cross_border", "joy", "demand_strength",
        ],
      },
    },
  },
  required: ["notes_md", "candidates"],
};

const FIT_SCHEMA = {
  type: "object",
  properties: {
    assessed: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string", description: "canonical title after merging" },
          merged_titles: {
            type: "array",
            items: { type: "string" },
            description: "source candidate titles folded into this one",
          },
          prior_art: {
            type: "string",
            description:
              "what FUTURE.md/NEXT.md/CURRENT.md/docs already plan, defer, " +
              "or shipped that overlaps (quote the section), or 'none'",
          },
          fit: { type: "string", enum: ["strong", "medium", "poor"] },
          fit_reason: { type: "string" },
          seams: {
            type: "string",
            description:
              "concrete existing modules/files it rides (grep-verified), " +
              "plus honest 'new subsystem required' flags",
          },
          effort: { type: "string", enum: ["S", "M", "L", "XL"] },
          riskiest_assumption: { type: "string" },
        },
        required: [
          "title", "merged_titles", "prior_art", "fit",
          "fit_reason", "seams", "effort", "riskiest_assumption",
        ],
      },
    },
    notes: { type: "string", description: "anything cross-cutting the PM should know" },
  },
  required: ["assessed", "notes"],
};

const SHORTLIST_SCHEMA = {
  type: "object",
  properties: {
    shortlist: {
      type: "array",
      maxItems: 12,
      items: {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "VERBATIM title from the assessed list",
          },
          framing: { type: "string", enum: ["new", "extend-backlog"] },
          why: { type: "string" },
          scores: {
            type: "object",
            properties: {
              severity: { type: "integer" },
              evidence: { type: "integer" },
              cross_border: { type: "integer", description: "1-5, weighted x2 in total" },
              effort: { type: "integer", description: "1-5, 5 = smallest" },
              joy: { type: "integer" },
            },
            required: ["severity", "evidence", "cross_border", "effort", "joy"],
          },
        },
        required: ["title", "framing", "why", "scores"],
      },
    },
    cut: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          reason: { type: "string", description: "one line, for the rejected appendix" },
        },
        required: ["title", "reason"],
      },
    },
  },
  required: ["shortlist", "cut"],
};

const VERDICT_SCHEMA = {
  type: "object",
  properties: {
    verdict: { type: "string", enum: ["kill", "survive"] },
    one_liner: { type: "string" },
    arguments: {
      type: "array",
      items: { type: "string" },
      description: "descending force; each names what was checked",
    },
    sharpest_surviving_weakness: {
      type: "string",
      description: "required on survive; empty string on kill",
    },
    checks: {
      type: "array",
      items: { type: "string" },
      description: "greps run, files read, links opened (with what was found)",
    },
  },
  required: ["verdict", "one_liner", "arguments", "sharpest_surviving_weakness", "checks"],
};

// ---- Phase 1: Research (4 parallel lenses) ---------------------------------

phase("Research");
log("Research: 2 competitor lenses + 2 demand lenses, in parallel");

const competitorRole =
  "ROLE (condensed from .agent/agents/competitor-analyst.md): read-only " +
  "competitor researcher. For EACH app assigned: inventory features from " +
  "primary sources (docs/changelogs/READMEs/release notes) and cross-check " +
  "against real user commentary (reviews, Reddit, HN, GitHub discussions); " +
  "separate the 2-4 DELIGHT features that demonstrably drive love/retention " +
  "in cited user commentary from checkbox features nobody celebrates; and " +
  "write a multi-currency/expat/cross-border subsection for EVERY app, even " +
  "when the answer is 'none — single-currency only' (that absence is signal). " +
  "Analyze everything through the lens: what would the owner of a " +
  "self-hosted US+MX tracker envy? Skip SaaS-monetization features. " +
  "Unverifiable -> say 'unverified', don't trust marketing.";

const voiceRole =
  "ROLE (condensed from .agent/agents/user-voice-researcher.md): read-only " +
  "demand-signal miner. A demand signal is a REAL user asking in public, " +
  "with a URL. Capture per signal: link, the literal ask (quote or tight " +
  "paraphrase), strength (upvotes/reactions/recurrence), recency, and why " +
  "current tools fail at it (declined issue, paywalled tier, US-only " +
  "assumption, cloud-only, ...). Recurrence across independent communities " +
  "is the strongest signal. Prioritize asks that recur AND every mainstream " +
  "tool fails at — especially multi-currency, cross-border, expat, " +
  "self-hosted, and household use cases. Three people asking is 'thin' — " +
  "label it thin.";

const researchers = await parallel([
  () =>
    agent(
      `${competitorRole}\n\nPRODUCT: ${PRODUCT}\n\n${PRIVACY}\n${CITE}\n\n` +
        `Your app slice — the mainstream connected-account trackers: ` +
        `Monarch Money, Copilot Money, YNAB, Lunch Money. ` +
        `${CANDIDATE_RULES}\n\nnotes_md = your per-app inventory section.`,
      { label: "competitors: mainstream", phase: "Research", schema: RESEARCH_SCHEMA },
    ),
  () =>
    agent(
      `${competitorRole}\n\nPRODUCT: ${PRODUCT}\n\n${PRIVACY}\n${CITE}\n\n` +
        `Your app slice — wealth/planning tools and the self-hosted/ ` +
        `open-source set: Kubera, ProjectionLab, Actual Budget, Firefly III, ` +
        `Ghostfolio, Maybe. For the open-source apps also note what their ` +
        `communities build as plugins/companions (that's unmet demand made ` +
        `visible). ${CANDIDATE_RULES}\n\nnotes_md = your per-app inventory section.`,
      { label: "competitors: wealth + self-hosted", phase: "Research", schema: RESEARCH_SCHEMA },
    ),
  () =>
    agent(
      `${voiceRole}\n\nPRODUCT: ${PRODUCT}\n\n${PRIVACY}\n${CITE}\n\n` +
        `Your slice — the open-source app communities and app-store pain: ` +
        `GitHub issues/discussions of Actual Budget, Firefly III, Ghostfolio, ` +
        `and Maybe sorted by reactions (record reaction counts and whether ` +
        `maintainers declined/stalled and why), plus app-store review pain ` +
        `points for Monarch/Copilot/YNAB (star patterns + representative ` +
        `quotes). ${CANDIDATE_RULES}\n\nnotes_md = your demand-landscape notes.`,
      { label: "demand: OSS issues + app stores", phase: "Research", schema: RESEARCH_SCHEMA },
    ),
  () =>
    agent(
      `${voiceRole}\n\nPRODUCT: ${PRODUCT}\n\n${PRIVACY}\n${CITE}\n\n` +
        `Your slice — community forums: r/ynab, r/personalfinance, r/fire, ` +
        `r/expats and Mexico-expat communities (r/MexicoExpats, expat forums), ` +
        `plus Hacker News and Bogleheads/MMM threads on personal-finance ` +
        `tooling. Give the cross-border/expat pain its own weight — that's ` +
        `Patrimonio's niche. ${CANDIDATE_RULES}\n\nnotes_md = your ` +
        `demand-landscape notes.`,
      { label: "demand: reddit + expat + forums", phase: "Research", schema: RESEARCH_SCHEMA },
    ),
]);

const LENSES = ["comp-mainstream", "comp-wealth-oss", "voice-oss", "voice-forums"];
const allCandidates = researchers.flatMap((r, i) =>
  r ? (r.candidates || []).map((c) => ({ ...c, source: LENSES[i] })) : [],
);
const liveCount = researchers.filter(Boolean).length;
if (liveCount < 4) log(`WARNING: ${4 - liveCount}/4 researchers returned nothing — coverage is partial`);
log(`Research done: ${allCandidates.length} raw candidates from ${liveCount}/4 researchers`);
if (allCandidates.length === 0) return { error: "no candidates surfaced; nothing to assess" };

// ---- Phase 2: Fit & feasibility (barrier is genuine: dedup needs all) ------

phase("Fit");

const fitRole =
  "ROLE (condensed from .agent/agents/fit-and-feasibility-analyst.md): " +
  "repo-read-only analyst, NO web. First read (skim where long): AGENTS.md, " +
  "docs/architecture.md, docs/backend.md, docs/multi-currency.md, " +
  "work/FUTURE.md, work/NEXT.md, and the newest 2-3 entries of " +
  "work/CURRENT.md. Grep backend/src/ and frontend/lib/ to confirm any seam " +
  "you claim — never assert one from memory; a made-up seam poisons the " +
  "PM's scoring. Per candidate: (1) fold near-duplicates and record the " +
  "merged titles; (2) prior art — quote what FUTURE.md/NEXT.md/CURRENT.md/" +
  "docs already plan, defer, or shipped that overlaps; (3) fit for a " +
  "self-hosted single-family deployment (strong/medium/poor + reason); " +
  "(4) seams — concrete modules/files it rides, with honest 'new subsystem " +
  "required' flags; (5) effort S(<=1d)/M(<=1wk)/L(<=1mo)/XL + the single " +
  "riskiest assumption. Don't kill candidates — but say plainly when " +
  "feasibility is poor.";

const fit = await agent(
  `${fitRole}\n\nRepo root: ${REPO}. Today is ${DATE}.\n\n` +
    `Candidate list from the researchers (JSON):\n` +
    JSON.stringify(allCandidates, null, 1),
  { label: "fit & feasibility", phase: "Fit", schema: FIT_SCHEMA },
);
if (!fit) return { error: "fit analyst died", allCandidates };
log(`Fit done: ${fit.assessed.length} assessed after merging`);

// ---- Phase 3: PM triage -----------------------------------------------------

phase("Triage");

const pmRole =
  "ROLE (condensed from .agent/agents/pm-synthesizer.md): you are the PM " +
  "and own the final call. Score each candidate 1-5 on: problem severity " +
  "(per the evidence, not imagination); demand-evidence strength (thin " +
  "evidence caps at 2 no matter how good the idea sounds); cross-border-" +
  "moat fit (COUNTS DOUBLE — features nobody else builds because they " +
  "don't serve US+MX users are Patrimonio's reason to exist); effort " +
  "(inverted, 5 = smallest, from the fit analyst's size); joy (would the " +
  "owner smile using it — 'useful but joyless' scores low). Duplicates of " +
  "work/FUTURE.md or work/NEXT.md don't get a slot; a candidate whose " +
  "research adds real evidence to a backlog item may be framed " +
  "'extend-backlog' instead.";

const triage = await agent(
  `${pmRole}\n\nPRODUCT: ${PRODUCT}\n\nRepo root: ${REPO} (read work/FUTURE.md ` +
    `and work/NEXT.md yourself to check duplication claims). Today is ${DATE}.\n\n` +
    `Shortlist 8-12 (fewer only if the pool is genuinely weaker than 8). ` +
    `Copy titles VERBATIM from the assessed list. Everything not shortlisted ` +
    `goes in 'cut' with a one-line reason for the rejected appendix.\n\n` +
    `Fit-assessed candidates (JSON):\n${JSON.stringify(fit.assessed, null, 1)}\n\n` +
    `Original research candidates with evidence links (JSON):\n` +
    JSON.stringify(allCandidates, null, 1),
  { label: "PM triage", phase: "Triage", schema: SHORTLIST_SCHEMA },
);
if (!triage) return { error: "PM triage died", allCandidates, fit };
log(`Triage done: ${triage.shortlist.length} shortlisted, ${triage.cut.length} cut`);

// ---- Phase 4: one skeptic per shortlisted candidate -------------------------

phase("Skeptics");

const skepticRole =
  "ROLE (condensed from .agent/agents/feature-skeptic.md): adversarial " +
  "reviewer for exactly ONE candidate — your job is to KILL it, but only " +
  "with verified arguments. Run every kill test: (1) already planned or " +
  "shipped — grep work/FUTURE.md, work/NEXT.md, work/CURRENT.md, docs/ for " +
  "the feature and synonyms (genuinely NEW evidence/scope on a backlog item " +
  "= downgrade-to-extension, say so); (2) demand evidence weak — OPEN the " +
  "cited links, report what you actually found (dead link, tiny engagement, " +
  "ancient thread); (3) breaks the self-hosted/privacy ethos (third-party " +
  "cloud, phones home, SaaS-scale infra); (4) the data source can't support " +
  "it (Plaid field coverage, MX CSV/PDF parser limits, FX feed granularity " +
  "— check the repo before asserting); (5) wrong niche for a cross-border " +
  "US+MX single-family self-hosted user. Never kill on taste. A survive " +
  "verdict must still name the sharpest surviving weakness. " + PRIVACY;

const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const assessedByTitle = new Map(fit.assessed.map((a) => [norm(a.title), a]));
const candidateByTitle = new Map(allCandidates.map((c) => [norm(c.title), c]));

const shortIds = triage.shortlist.slice(0, 12);
if (triage.shortlist.length > 12) log(`Capping skeptic pass at 12 of ${triage.shortlist.length} shortlisted`);

const verdicts = await parallel(
  shortIds.map((s) => () => {
    const a = assessedByTitle.get(norm(s.title)) || null;
    const sources = a
      ? a.merged_titles.map((t) => candidateByTitle.get(norm(t))).filter(Boolean)
      : [candidateByTitle.get(norm(s.title))].filter(Boolean);
    return agent(
      `${skepticRole}\n\nRepo root: ${REPO}. Today is ${DATE}.\n\n` +
        `PRODUCT: ${PRODUCT}\n\n` +
        `THE CANDIDATE TO ATTACK:\n${JSON.stringify({ shortlist_entry: s, fit_assessment: a, research_candidates: sources }, null, 1)}`,
      { label: `skeptic: ${s.title.slice(0, 40)}`, phase: "Skeptics", schema: VERDICT_SCHEMA },
    ).then((v) => ({ title: s.title, verdict: v }));
  }),
);
const verdictList = verdicts.filter(Boolean);
log(
  `Skeptics done: ${verdictList.filter((v) => v.verdict && v.verdict.verdict === "survive").length} survive, ` +
    `${verdictList.filter((v) => v.verdict && v.verdict.verdict === "kill").length} kill recommendations`,
);

// ---- Phase 5: PM synthesis ---------------------------------------------------

phase("Synthesis");

const synthesis = await agent(
  `${pmRole}\n\nFINAL PASS. Today is ${DATE}. Repo root: ${REPO}.\n\n` +
    `Rules: survivors only — a skeptic kill you AGREE with moves the idea to ` +
    `the rejected appendix with a one-line reason. You may overrule a skeptic, ` +
    `and a researcher may have loved something a skeptic killed — in both ` +
    `cases RECORD the disagreement inside the brief ("skeptic argued X; kept ` +
    `because Y"), never silently resolve it. Thin evidence is stated as thin ` +
    `in the brief, not laundered. Preserve the evidence URLs.\n\n` +
    `Return ONLY a markdown document (no preamble) with exactly these ` +
    `sections:\n` +
    `# Feature research — ${DATE}\n` +
    `## Executive summary — a short table of the final picks (title, score, ` +
    `effort, one-line pitch), then 3-5 sentences on the shape of what the ` +
    `research found.\n` +
    `## Briefs — one '### N. <title>' per survivor, each with EXACTLY these ` +
    `bolded fields: **Problem**, **Demand evidence** (linked, with strength ` +
    `and recency), **Competitor landscape** (how others do it or fail to), ` +
    `**Proposed Patrimonio shape** (riding the fit analyst's verified seams), ` +
    `**Effort** (T-shirt + what drives it), **Riskiest assumption**, ` +
    `**Joy rationale**, **Skeptic's challenge** (their sharpest point + any ` +
    `recorded disagreement).\n` +
    `## Proposed FUTURE.md additions — a fenced diff-style block of new ` +
    `sections for the top picks, written to match FUTURE.md's existing voice ` +
    `(Status/Tracking headers, acceptance sketch). Preceded by one line: this ` +
    `is a PROPOSAL; the owner applies it after review.\n` +
    `## Appendix A — researched and rejected: EVERY dropped idea (triage cuts ` +
    `+ skeptic kills you upheld + fit-analyst early rejects) as '- **title** — ` +
    `one-line reason', so the next session doesn't re-research them.\n\n` +
    `INPUTS:\n` +
    `Shortlist with scores:\n${JSON.stringify(triage.shortlist, null, 1)}\n\n` +
    `Skeptic verdicts:\n${JSON.stringify(verdictList, null, 1)}\n\n` +
    `Fit assessments:\n${JSON.stringify(fit.assessed, null, 1)}\n\n` +
    `Fit analyst's cross-cutting notes: ${fit.notes}\n\n` +
    `Research candidates (evidence URLs live here):\n` +
    `${JSON.stringify(allCandidates, null, 1)}\n\n` +
    `Triage cuts:\n${JSON.stringify(triage.cut, null, 1)}`,
  { label: "PM synthesis", phase: "Synthesis" },
);

return {
  reportMd: synthesis,
  appendixNotes: {
    compMainstream: (researchers[0] || {}).notes_md || "",
    compWealthOss: (researchers[1] || {}).notes_md || "",
    voiceOss: (researchers[2] || {}).notes_md || "",
    voiceForums: (researchers[3] || {}).notes_md || "",
  },
  stats: {
    rawCandidates: allCandidates.length,
    assessed: fit.assessed.length,
    shortlisted: triage.shortlist.length,
    skepticKills: verdictList.filter((v) => v.verdict && v.verdict.verdict === "kill").length,
  },
  shortlist: triage.shortlist,
  verdicts: verdictList,
};
