---
sha: bfc5abde96c649cd85986493dde68c794dacc68d
short_sha: bfc5abd
audited_at: 2026-06-10
auditor_model: grok-4.3
verdict: clean + 1 hygiene fix
audited_by: post-merge audit agent (harness)
---

# Audit: bfc5abd (post-merge hygiene pass over 5598f48..ea19a4f range)

**Anchor commit:** bfc5abd — `roadmap: task 106 -> done (shipped 5598f4889917)`
**Landed range reviewed:** ea19a4f..bfc5abd (per task list: 5147dfb feat(73f), 2827213+5f97220 task 132, f3a3042+5dae68c task 133, 7f2e8e4 sentinel fix, 4a78dad corpus bump, 8a881e9 deps, 8034e34 zenhive+harness plugin, 9b0220f CLAUDE slim, ea19a4f task 62, plus harness delivery/roadmap state commits)
**Files touched (code+docs, non-bulk):** ~15 source (raw_broadcast, transaction_classification, contract_test, error_dispatch, symbol_patterns, pipeline, discovery_loader, mix tasks, tests, SCHEMA, CHANGELOG, CLAUDE, AGENTS, .claude/settings, .mcp.json, .gitignore, mix.exs/lock)
**Key themes in range:** Task 73f (raw broadcast promotion for on_chain tx classification on DEX non-unified paths), Task 132 (http_status predicate split eq vs range), Task 133 (explicit error_class_hierarchy content equality invariant), Task 106 (drifted override fixture), CCXT 4.5.56 regen, deps bumps (oxc/quickbeam/reach), marketplace migration to zenhive + harness plugin/MCP registration, CLAUDE.md slim to Opus-4.8 floor + reviewer toolchain section.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | convention | lib/ccxt_extract/raw_broadcast.ex:72-87 | New OXC extractor (Task 73f) omits `@spec` on the three `@impl true` callbacks (`source_dir/0`, `extract_from_ast/2`, `write_stats/1`). Sibling recent extractors (ws_heartbeat, ws_auth) and OXCExtractor behaviour docs use the explicit `@spec` after `@impl` pattern for the callbacks. | Fixed forward (this audit commit) — added matching `@spec` lines. No behavior change. |

## Auto-applied fixes

- Added the three `@spec` annotations on OXC callbacks in `raw_broadcast.ex` to match current project convention for extractor modules (see ws_* and behaviour @callback docs). Verified: `mix format --check-formatted`, compile clean, relevant unit tests (210 passed) green.

## Findings considered & dropped

- **CHANGELOG gaps:** None. Unreleased section has detailed, accurate entries for 73f, 132, 133, 106, the sentinel fix, the CCXT bump, dep refresh, and the validate_overrides (62) surface. Matches CLAUDE.md "every task must update docs in lockstep".
- **Debug / leftover output:** None in new code (raw_broadcast, transaction_classification updates, new tests). Grep for IO.inspect/dbg across range changes was clean.
- **Bare TODOs:** None introduced. The three pre-existing TODOs in the tree are old (Task 68, 30, integration floor note) and either tagged or justified.
- **Credo disables / skips:** The two `credo:disable-for-next-line Credo.Check.Refactor.Apply` in contract_test (for optional Reach dep) predate the range (Task 112) and are documented with rationale. No new ones.
- **.gitignore / corpus symlink hygiene:** Already addressed in-land by f3a3042 (reviewer fixes for 133): added `/priv/output` (symlink catch-all) and untracked the accidental absolute-path entry from the implementer commit. Good.
- **Test quality:** New tests (raw_broadcast_test, transaction_classification_test additions, contract_test invariant tests, symbol_patterns sentinel test) are useful boundary + behavior coverage, not trivial asserts. Integration tests added for 73f are tagged appropriately.
- **Schema / doc drift:** SCHEMA.md received a targeted update documenting the new invariant + promotion behavior. CLAUDE.md slim was intentional (Opus-4.8 selective-load + self-contained reviewer section for AGENTS.md consumers). No stale references in the changed surfaces.
- **Dead code / inconsistent naming:** None. New RawBroadcast module is tight (transitive fixpoint, clear gates), reuses TransactionClassification.transactional?/1 as the single source of truth. Pipeline parent-fallback for raw_broadcast mirrors existing DEX alias patterns. Naming is consistent with prior extractors.
- **Config / plugin changes (8034e34, 9b0220f):** Clean registration of harness@zenhive + MCP endpoint; extraKnownMarketplaces update; CLAUDE eager-floor reduction documented with skill mapping. Matches the project's own CLAUDE.md philosophy section.
- **Sobelow / doctor / compile:** All pre-existing low-confidence FileModule findings (generator write paths are trusted); doctor 100% coverage; compile --warnings-as-errors clean on the fix.
- **Roadmap / harness meta commits:** Reviewed for surface impact only (no code changes to audit beyond the listed deliveries). Per rules, did not touch roadmap/tasks.toml or ROADMAP.md.

## Audit notes

Range was high-signal, low-hygiene-debt. The 73f work (salvaged from a prior killed run) landed with comprehensive CHANGELOG prose, contract-test guard, integration coverage for hyperliquid/paradex/grvt/lighter, and conservative promotion bias documented. Reviewer interventions (2827213 for predicate split line-wraps; f3a3042 for format + symlink) were already applied in the landed commits. The single fix here is a pure style alignment that would have been caught by a reviewer or the post-edit hook; fixing forward as required.

No reviewer rejections recorded for this project in the provided context (the note "no reviewer rejections recorded for this project" was taken as given; nothing in the landed diffs contradicted the acceptance criteria of the originating tasks).

The `.harness/audit.json` machine summary was written (harness-internal, not committed).

## Verification performed

- `mix format --check-formatted` (on edit)
- `mix compile --warnings-as-errors` (clean)
- `mix credo --strict --ignore TagTODO,TagFIXME` (no issues)
- `mix doctor --raise` (passed; 100% doc/spec cov on touched modules)
- `mix sobelow` (expected low-conf traversal findings only; scan complete)
- Targeted unit tests (raw_broadcast, transaction_classification, symbol_patterns, contract_test, error_dispatch): 210 passed, result "passed" (under CCXT_EXTRACT_SKIP_CORPUS_CHECK=1)
- Grep hygiene scans (debug, bare TODO, credo-disable, skip tags) on range + new files
- Manual diff review of 5147dfb (main), 2827213, 7f2e8e4, f3a3042, pipeline/disco wiring, tests, docs, configs

**Next audit marker:** the commit created by this audit (`audit(bfc5abd): ...`).
