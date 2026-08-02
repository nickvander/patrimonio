// quality-sweep — repeatable READ-ONLY audit of the Patrimonio repo.
//
// Deliberate design choice: this sweep only OBSERVES. It establishes a gate
// baseline and collects ranked findings; it never fixes anything. Fixes are
// judgment calls (audits have been wrong before) and are done as follow-ups —
// typically by launching the `fixer` agent (.agent/agents/fixer.md) on the
// findings you accept. Workflow subagents cannot read .agent/agents/*, so the
// gate commands / env facts below are embedded copies of what the
// backend-verifier / frontend-verifier definitions encode — if a gate command
// changes, update both places.

export const meta = {
  name: "quality-sweep",
  description:
    "Read-only quality sweep: run both verification gate sets in parallel " +
    "(baseline), then three parallel skill-grounded audits (backend, " +
    "frontend, cross-cutting docs/CI). Reports; never modifies files.",
  whenToUse:
    "Periodically, or before/after a large piece of work, to get an honest " +
    "gate baseline plus ranked file:line findings. Not for making fixes — " +
    "act on the findings afterwards with the fixer agent.",
  phases: ["Baseline", "Audit"],
};

// ---- Shared instruction fragments -----------------------------------------

const READ_ONLY =
  "You are READ-ONLY: never edit, write, format, or fix any file. " +
  "Run verification commands in the foreground and never finish while one " +
  "is still running; report only results you actually captured.";

const gateSchema = {
  type: "object",
  properties: {
    gates: {
      type: "array",
      items: {
        type: "object",
        properties: {
          gate: { type: "string", description: "command run" },
          pass: { type: "boolean" },
          counts: {
            type: "string",
            description:
              "exact totals, e.g. '291 unit passed; 217 integration passed, 0 failed' or 'clean'",
          },
        },
        required: ["gate", "pass", "counts"],
      },
    },
  },
  required: ["gates"],
};

const auditSchema = {
  type: "object",
  properties: {
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          file: { type: "string", description: "absolute path" },
          line: { type: "integer" },
          summary: { type: "string", description: "one-sentence defect" },
          why: { type: "string", description: "house rule / bug class it violates" },
          severity: { type: "string", enum: ["critical", "high", "medium", "low"] },
        },
        required: ["file", "line", "summary", "why", "severity"],
      },
    },
    healthy: {
      type: "array",
      items: { type: "string" },
      description: "areas checked that held up",
    },
  },
  required: ["findings", "healthy"],
};

const auditPrompt = (scope, skills, focus) =>
  `${READ_ONLY} FIRST read ${skills} in full — judge only against those house ` +
  `conventions and known bug classes, never generic taste. Audit ${scope}. ${focus} ` +
  `Verify every finding by reading the cited code (no speculation from names); ` +
  `each finding = file:line + one-sentence defect + why (tie to a house rule) + ` +
  `severity critical|high|medium|low. Rank by value; include healthy areas.`;

// ---- The sweep ------------------------------------------------------------

export default async function ({ agent, parallel, phase, log }) {
  // Phase 1 — Baseline: both gate sets in parallel. Infra failures (test
  // DB/Redis down → the harness PANICS loudly by design) are reported as
  // infra, not code.
  const [backendGates, frontendGates] = await phase("Baseline", () =>
    parallel([
      agent(
        `${READ_ONLY} Run the Patrimonio backend gate set, in order, each Bash call ` +
          `prefixed with 'source ~/.cargo/env' and cd /home/nickvander/dev/patrimonio/backend: ` +
          `(1) cargo fmt --check; (2) cargo clippy --all-targets -- -D warnings; ` +
          `(3) PATRIMONIO_TEST_DATABASE_URL="postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio_test" ` +
          `PATRIMONIO_TEST_REDIS_URL="redis://:patrimonio_dev@127.0.0.1:6380" cargo test ` +
          `— NEVER point tests at the dev DB 'patrimonio' (tests TRUNCATE). The full suite ` +
          `takes ~10 min: use a >=600000 ms Bash timeout. A panic on unreachable DB/Redis ` +
          `means infra is down, not broken code — say which. Report per-suite pass/fail ` +
          `counts and exact totals.`,
        { label: "backend gates", phase: "Baseline", schema: gateSchema },
      ),
      agent(
        `${READ_ONLY} Run the Patrimonio frontend gate set, in order, from ` +
          `/home/nickvander/dev/patrimonio/frontend (Flutter is at ~/flutter/bin): ` +
          `(1) ~/flutter/bin/dart format --set-exit-if-changed lib test; ` +
          `(2) ~/flutter/bin/flutter analyze --no-fatal-infos — 18 pre-existing infos are ` +
          `the accepted baseline, flag only increases/warnings/errors; ` +
          `(3) ~/flutter/bin/flutter test --exclude-tags golden. Report exact counts.`,
        { label: "frontend gates", phase: "Baseline", schema: gateSchema },
      ),
    ]),
  );
  log("Baseline captured; starting audits");

  // Phase 2 — Audit: three parallel skill-grounded, read-only auditors.
  const skillsDir = "/home/nickvander/dev/patrimonio/.agent/skills";
  const [backend, frontend, crosscut] = await phase("Audit", () =>
    parallel([
      agent(
        auditPrompt(
          "backend/src and backend/tests",
          `${skillsDir}/rust-backend/SKILL.md (and its rust-conventions.md)`,
          "Priorities: user_id scoping, per-row FX before summing money, " +
            "balance_snapshots carry-forward (never per-date GROUP BY), ApiError/internal() " +
            "on 500s, loud test-skip, no query! macros.",
        ),
        { label: "backend audit", phase: "Audit", schema: auditSchema },
      ),
      agent(
        auditPrompt(
          "frontend/lib and frontend/test",
          `${skillsDir}/flutter-frontend/SKILL.md (and its dart-flutter-conventions.md)`,
          "Priorities: gen-l10n alphabetical placeholder order at call sites, both arb " +
            "files updated, no hand-rolled money/percent strings, no hardcoded colors, " +
            "no top-level http.* calls, web-only imports behind conditional-import seams.",
        ),
        { label: "frontend audit", phase: "Audit", schema: auditSchema },
      ),
      agent(
        auditPrompt(
          "cross-cutting surfaces: AGENTS.md, .agent/skills/, .github/workflows/, docs/, work/CURRENT.md",
          `${skillsDir}/dev-workflow/SKILL.md and ${skillsDir}/work-tracking/SKILL.md`,
          "Priorities: docs/skills that contradict the code or each other (stale commands, " +
            "moved files, dead paths), CI gates that drifted from AGENTS.md, secrets or " +
            "private operational detail under docs/ (it publishes publicly).",
        ),
        { label: "cross-cutting audit", phase: "Audit", schema: auditSchema },
      ),
    ]),
  );

  // Consolidate: findings sorted by severity (then keep auditor order).
  const rank = { critical: 0, high: 1, medium: 2, low: 3 };
  const findings = [
    ...backend.findings.map((f) => ({ area: "backend", ...f })),
    ...frontend.findings.map((f) => ({ area: "frontend", ...f })),
    ...crosscut.findings.map((f) => ({ area: "cross-cutting", ...f })),
  ].sort((a, b) => (rank[a.severity] ?? 9) - (rank[b.severity] ?? 9));

  return {
    baseline: { backend: backendGates, frontend: frontendGates },
    findings,
    healthy: {
      backend: backend.healthy,
      frontend: frontend.healthy,
      crossCutting: crosscut.healthy,
    },
  };
}
