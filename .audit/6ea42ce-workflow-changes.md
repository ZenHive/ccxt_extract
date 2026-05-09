# Audit — `6ea42ce` workflow changes, add. tests

- **Commit:** `6ea42ce` (parent: `e1ce696`)
- **PR:** none — direct push to `development`
- **LOC:** 3533 (3531 insertions, 2 deletions)
- **lib/ files touched:** 0
- **Files (4):** `AGENTS.md` (new, 3524 lines), `CLAUDE.md`, `test/ccxt_extract/aggregate_writer_test.exs`, `test/ccxt_extract/overrides_test.exs`
- **Path:** FULL machinery (LOC ≥ 100; LOC threshold dominates the no-lib/ classifier)
- **Reviewers:** Claude (audit-review Step 5a) + Codex CLI (Step 5b — `codex:codex-rescue` parallel dispatch)
- **Verdict:** clean — 1 corroborated cross-file consistency finding auto-applied (C2 port mismatch); 1 docs-drift finding filed as ROADMAP follow-up (C3); 0 new defects.

## Reviewer convergence

| Finding | Claude | Codex | Disposition |
|---|:---:|:---:|---|
| **C2** — `localhost:4001` in `CLAUDE.md:175` and `AGENTS.md:3488` contradicts `mix.exs:81` + `.mcp.json` (both `4002`) | — | ✅ | Codex-only — verified via `grep -rn "4001\|4002" mix.exs .mcp.json CLAUDE.md AGENTS.md` (mix.exs/.mcp.json both `4002`; CLAUDE.md/AGENTS.md both `4001`). Promoted to auto-apply: mechanical rename, ratable as 4/10 (actionable + correctness). |
| **C3** — `AGENTS.md` ships ~15 references to cloud-agent flows (`[CSR]`, `[CX]`, "Cursor Delegation Flow") but ROADMAP.md § Notes documents cloud-agent delegation as retired | — | ✅ | Codex-only — verified via `grep -c "CSR\|CX\b\|Cursor\|Codex" AGENTS.md` (50+ hits). Generator-side fix (AGENTS.md is bundled from `~/.claude/includes/*.md`). Filed as ROADMAP Task 132 — out of scope for one-line audit-commit fix. |

## Auto-applied fixes (audit-review Step 9)

### Fix 1 — `CLAUDE.md:175` (Tidewave port)

`mix tidewave   # listens on http://localhost:4001` → `mix tidewave   # listens on http://localhost:4002`

**Why:** mix.exs:81 binds Tidewave to port 4002 (`Bandit.start_link(plug: Tidewave, port: 4002)`); `.mcp.json` registers `http://localhost:4002/tidewave/mcp`. The CLAUDE.md doc string drifted (likely copied from a template before the port-conflict resolution that moved this project off 4001). Doc → reality reconciliation.

### Fix 2 — `AGENTS.md:3488` (Tidewave port — bundled-include mirror)

Same single-line rename as Fix 1. AGENTS.md is the user's bundled `~/.claude/includes/*.md` snapshot rendered into the repo for cross-tool agent visibility; the same line drift exists at the same position because both source from the same prose template.

## Verification

- **Compile:** offline (will be exercised by post-commit hook chain)
- **Tests:** `mix test.json --quiet --output /tmp/audit-r.json` running in background — see commit-message verification block.
- **Honest scope:** offline tests only — `:extraction`, `:tier3_corpus`, `:flaky` excluded by `test/test_helper.exs:50`. The two doc-only fixes here don't cross any test boundary, so the fast suite is sufficient evidence for them.

## Out-of-scope (filed as follow-up)

- **C3 — `AGENTS.md` cloud-agent drift** → ROADMAP **Task 132** (`[D:2/B:3/U:3 → Eff:1.5] 🚀`). Generator-side fix: drop `linear-workflow.md`/`delegation-rules.md` includes from this repo's bundle, OR add a top-of-file callout that cloud-agent sections are reference-only. Per Ceremony Floor (`task-prioritization.md` § "Ceremony Floor"), >5 LOC, cosmetic-tier, with cross-session coordination cost (the bundled-include generator lives outside this repo) → ROADMAP candidate.
- **3531-line bulk diff (AGENTS.md introduction)** — scanned for additional Cat 1 bugs / Cat 6 doc-drift beyond C2/C3; none found. The bundle is internally consistent for non-cloud-agent guidance.
