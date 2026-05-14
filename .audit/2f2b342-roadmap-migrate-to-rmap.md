---
sha: 2f2b34222d5878a56be0835b55e3681bc341ec84
short_sha: 2f2b342
audited_at: 2026-05-14
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: roadmap: migrate to rmap (typed tasks.toml source of truth) (#29)

**Original commit:** 2f2b342 — `roadmap: migrate to rmap (typed tasks.toml source of truth) (#29)`
**Author:** E.FU
**Files touched:** 6 (CHANGELOG.md, CLAUDE.md, ROADMAP.md, roadmap/data.json, roadmap/tasks.toml, lib/ccxt_extract/request_defaults.ex)
**LOC:** +2269 / −187

Migrates the hand-maintained `ROADMAP.md` to the `rmap` CLI: `roadmap/tasks.toml` is
the new typed source of truth, `ROADMAP.md` + `roadmap/data.json` are generated views.
The only production-code change is a `@moduledoc` comment in `request_defaults.ex`.

**Claude's structural pass found the commit clean:** `rmap validate` and
`rmap validate --check-render` exit 0 with a clean `git status` (ROADMAP.md + data.json
exactly match `rmap render` from tasks.toml — no render drift); task count 53 = 37
pending + 16 blocked matches the PR; no duplicate IDs; all `depends_on` / `bundle`
references resolve; the `request_defaults.ex` moduledoc's new reference ("Three-Strikes
escalation for Task 73c note in ROADMAP.md (Phase 11 section)") is accurate against the
rendered ROADMAP.md (line 198, Phase 11 section); the 7-task `PROPOSED SCORES` list in
the tasks.toml header comment and CHANGELOG are internally consistent. All findings
below came from the Codex second-opinion — the dual-reviewer split working as designed.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 4 | doc-gap | CHANGELOG.md:16 | "for non-priority exchanges" inaccurate — blocked tasks name Tier 1/2 exchanges | applied |
| 2 | — | doc-gap (codex, over-flag) | AGENTS.md (generated) | AGENTS.md Documentation-invariants still says hand-edit ROADMAP.md | noted only — not applied |
| 3 | discuss-design | roadmap-health | roadmap/tasks.toml | `rmap doctor`: 9 tasks missing `acceptance_criteria` + 1 degenerate bundle | dialogue-resolved (convergent) → filed as Task 141 |

## Auto-applied fixes

- **CHANGELOG.md:16** — The "Scope-creep verdict applied natively" entry said the
  `10-sign-extend` / `sibling-emit` bundles "extend closed phases **for non-priority
  exchanges** with no `ccxt_client` consumer pull." Verified against the actual blocked
  tasks: 66e names Deribit/HTX/Phemex/Kraken/Gate, 66f names Binance/Bybit, 113 names
  htx, 128 names okx/bitfinex — all Tier 1/2. Each task's `blocked_reason` says "No
  priority *consumer*" — the deferral is about no `ccxt_client` consumer pull, not about
  the exchanges being non-priority. Reworded the CHANGELOG to drop the inaccurate clause
  and cite the `blocked_reason` framing.

## Discuss-tier resolutions

- **(dialogue-resolved: Task 141 filed)** — `rmap doctor` (run during the audit, exit
  shows 10 findings) flags 9 D≥5/B≥8 tasks lacking `acceptance_criteria` and bundle
  `12-simple` as "degenerate" (covers all 4 open Phase 12 tasks). Classified
  `discuss-design`: auto-applying would mean authoring 9 acceptance-criteria sets and
  restructuring a bundle — substantive editorial content the migration deliberately
  didn't undertake (the source `ROADMAP.md` had no structured criteria; `12-simple` is
  deliberately "the non-gating Phase 12 remainder").
  **Claude position:** file one follow-up — `rmap doctor` is advisory, the documented
  gate (CLAUDE.md § Documentation invariants) is `rmap validate --check-render` which
  passes; authoring criteria is new content, not audit hygiene.
  **Codex position (independent):** same — choose (b), file one ROADMAP follow-up;
  Codex additionally verified in the `../rmap` source that `rmap doctor` is explicitly
  advisory-only, and that removing a deliberately-described phase-remainder bundle would
  be new editorial work.
  **Convergent** → resolution applied as the agreed action: filed `roadmap/tasks.toml`
  Task 141 (Phase 0, `maintenance` bundle, proposed scores D:3/B:3/U:3 flagged
  `PROPOSED SCORES` per the repo's established convention for unconfirmed scores), then
  `rmap render` regenerated ROADMAP.md + data.json. Not a divergence-drop — both
  reasoners agreed the resolution IS "file a tracked follow-up."

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (Claude's pass found the commit clean; all findings Codex-originated)
Codex-only findings (verified → applied): 1
Codex-only findings (verified → discuss-design dialogue): 3
Codex-only findings (verified context → noted, not applied): 2 — Codex rated 8: AGENTS.md
  still tells agents to hand-edit the (now-generated) ROADMAP.md. Verified, but the
  commit already handles it: the CHANGELOG explicitly documents the transient drift and
  notes AGENTS.md's Documentation-invariants section self-heals on the next
  CLAUDE.md → AGENTS.md marketplace sync (confirmed — that section is generated from the
  project CLAUDE.md, which this commit updated). AGENTS.md is generated ("do not edit
  manually"); hand-editing it is forbidden and would be overwritten. The cloud-agent
  strand of AGENTS.md drift is already tracked as Task 139. No in-repo action available
  or warranted — Codex over-flagged by not crediting the CHANGELOG's explicit handling.
Codex-only findings (discarded as over-flag): —
