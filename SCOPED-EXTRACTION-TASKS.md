# Scoped Extraction Refactor — Session Task Breakdown

> **Full design:** `~/.claude/plans/breezy-wandering-sloth.md` (referenced once, then forget).
> Each task below is sized for a single Claude Code session and produces working,
> committable code. Tasks are intentionally ordered by dependency — later tasks
> assume earlier ones are done.

## Vision

Tier flags (`--tier1/--tier2/--tier3/--dex`) and `--exchange <id>` scope the
**entire** extraction pipeline, not just the slow network stage. Default is
still all 111 exchanges (explicit `--all` or no scope flag). Out-of-scope
per-exchange files are deleted; aggregate discovery files are rewritten
with only in-scope keys. A git-status safety rail prevents accidental loss
of uncommitted work.

## New rule (replaces current "Tier-Based Scoping" in CLAUDE.md)

> The One Rule (**Extract EVERYTHING. Never filter.**) applies *per-exchange*
> — every field, every method, every AST node is extracted for every
> in-scope exchange. **Which exchanges are in scope** is controlled by
> scope flags (`--tier*`, `--exchange`, `--all`). Default is all 111.

---

## 🎯 Current Focus

**Task 2 landed.** Pipeline + orchestrator are scope-aware end-to-end:
`mix ccxt_extract.pipeline --tier1` assembles only in-scope exchanges,
prunes the rest from `priv/output/`, and stamps `tier_scope` in
`_manifest.json`. `mix ccxt_extract.update` gained a `--force`-gated
git-status safety rail and routes `scope_args` to the pipeline stage.
Tasks 3/4/5 can now proceed in parallel (see Task Graph).

**Known drift (post-Task 101):** cached integration tests are currently red for
two unrelated reasons, neither tied to the scope refactor: (1) `coincatch` is a
new CCXT exchange picked up by OXC-based extractors but absent from the stale
QuickBEAM fixtures — `--skip-setup` does not regenerate those, leaving orphaned
entries in discovery files (`test/integration/cached/pipeline_cached_test.exs:208`);
and (2) `parse_methods` coverage threshold dipped to 99 in
`test/integration/cached/coverage_report_cached_test.exs:88`. Both clear with a
full `mix ccxt_extract.update` (no `--skip-setup`) or by refreshing the cached
fixtures. The original envelope-total drift is resolved.

### Quick Commands

```bash
mix test.json --quiet --failed --first-failure           # Iterate on scope tests
mix ccxt_extract.pipeline --tier1 --dex                   # Smoke the scoped pipeline (after Task 2)
mix ccxt_extract.pipeline --exchange binance,deribit     # Single-exchange smoke (after Task 2)
jq '.tier_scope' priv/output/_manifest.json              # Verify manifest stamps scope
```

---

## Tasks

### Task 1: Scope + ScopeCleanup modules (foundation) ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-1-scope--scopecleanup-foundation-modules).
**Score:** [D:3/B:9/U:10 → Eff:3.17] 🎯

Implemented in `lib/ccxt_extract/scope.ex` + `lib/ccxt_extract/scope_cleanup.ex`.
36 unit tests (all fail-loud), 0 Credo strict issues. MapSet
`call_without_opaque` suppressions added to `.dialyzer_ignore.exs`
following the established project convention (`method_analysis.ex`,
`pipeline.ex`, `validation.ex`, etc.).

**Follow-up fixes (Codex review):** two contract violations corrected —
`ScopeCleanup.prune_out_of_scope/3` now only touches `.json` files
(was deleting any non-directory file, e.g. `README.md`), and
`Scope.resolve/2` now intersects tier-derived IDs with the
caller-supplied universe (previously tier expansion bypassed the
universe). See CHANGELOG "Task 1 follow-up" subsection.

**Original spec (retained for traceability):**

Implement two small, well-tested modules that every downstream task will use.

**`lib/ccxt_extract/scope.ex` — `resolve/2`:**
- Parse `--tier1/--tier2/--tier3/--dex`, `--all`, and `--exchange` (repeatable, comma-split accepted).
- Return `{:ok, exchanges_in_scope, :all | {:scoped, label}}` or `{:error, {:unknown_exchange, bad_ids}}`.
- Validate `--exchange` IDs against the caller-supplied universe list.
- On unknown IDs, compute fuzzy suggestions via `String.jaro_distance/2` (top 3, ≥0.7 threshold).
- Reject `--all` combined with any narrowing flag with a clear error.
- `label` format: `"TIER 1 + DEX + binance (7)"` (tier display names first, then individual exchanges, final count in parens).

**`lib/ccxt_extract/scope_cleanup.ex` — `prune_out_of_scope/3`:**
- Given a directory, an in-scope MapSet, and opts, delete per-exchange files not in scope.
- Preserve any filename starting with `_` (manifests, aggregate metadata).
- Per-exchange directory support too (e.g. `priv/discoveries/describe/<id>.json`).
- Return `{:ok, removed_paths}`.
- Also provide a `git_status_clean?/1` helper that runs `git status --porcelain <path>` and returns `:ok` or `{:error, dirty_files}`.

**Tests (mandatory, fail loudly):**
- Scope: tier union, exchange-only, mixed, comma-split, typo detection with suggestions, `--all` conflict, unknown ID with no close match (empty suggestions).
- ScopeCleanup: deletes correct files, preserves `_*` files, works on nested directory, no-op when in_scope covers everything, git-status returns dirty list correctly.

**Success criteria:**
- [ ] `mix test.json --quiet test/ccxt_extract/scope_test.exs` passes
- [ ] `mix test.json --quiet test/ccxt_extract/scope_cleanup_test.exs` passes
- [ ] `mix credo --strict --format json` reports 0 issues on new files
- [ ] `mix dialyzer.json --quiet` reports 0 new warnings

**Files touched:** 2 new lib files + 2 new test files.

---

### Task 2: Wire Scope into pipeline + orchestrator ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-2-scope-aware-pipeline--orchestrator).
**Score:** [D:5/B:9/U:9 → Eff:1.8] 🚀

Landed `--tier*/--all/--exchange` on both
`mix ccxt_extract.pipeline` and `mix ccxt_extract.update`, plus a
`--force`-gated git-status safety rail on the orchestrator only.
`Pipeline.extract/1` filters assembly by `:scope`, `Pipeline.write!/3`
stamps `tier_scope` via the new `Scope.to_manifest_value/1` helper,
and `clean_stale_files/2` was replaced with
`ScopeCleanup.prune_out_of_scope/3` (preserving `exchange_v1.json` and
`_`-prefixed metadata). `mix ccxt_extract.update` aborts when
`priv/output/` or `priv/discoveries/` has uncommitted changes (bypass
with `--force`). Direct `mix ccxt_extract.pipeline` invocations still
prune without a safety rail — tracked as Task 10. 21 new tests across
`pipeline_test.exs`, `scope_test.exs`, `update_test.exs`, and a new
`test/mix/tasks/pipeline_test.exs`. **Scope boundary:** `scope_args`
only reaches pipeline/load_markets/contract_test in this PR — other
extractor stages pick up scope flags as Tasks 3–7 land.

**Original spec (retained for traceability):**

Make the pipeline and `mix ccxt_extract.update` scope-aware end-to-end. This
proves the design works before fanning out to per-task changes.

**`lib/mix/tasks/ccxt_extract.pipeline.ex`:**
- Add `--tier1/--tier2/--tier3/--dex/--all/--exchange` switches (use `:keep` for `--exchange`).
- Call `Scope.resolve/2` with the discovered exchange list.
- Pass the scope into `CcxtExtract.Pipeline.extract/1`.
- Write a new `tier_scope` field into `_manifest.json` (either `"all"` or a list like `["tier1", "dex", "exchange:binance"]`).
- After writing all per-exchange JSONs, invoke `ScopeCleanup.prune_out_of_scope/3` on `priv/output/`.

**`lib/ccxt_extract/pipeline.ex`:**
- `extract/1` accepts a `:scope` option (defaults to `:all`). Filters the exchange list before iterating.

**`lib/mix/tasks/ccxt_extract.update.ex`:**
- Add `--all` and `--exchange` (`:keep`) to `@switches`.
- Replace ad-hoc `tier_args/1` with a `scope_args/1` that emits the full scope flag set (`--tier*` + each `--exchange value`).
- Pass `scope_args(opts)` to **every** stage's `Mix.Task.rerun/2` call, not just `load_markets` and `contract_test`.
- Before running destructive stages, call `ScopeCleanup.git_status_clean?/1` on `priv/output/` and `priv/discoveries/`. Abort unless `--force` is passed.
- Update `@moduledoc` to document new flags and the deletion policy.

**Tests:**
- Pipeline task test: assert `_manifest.json` includes `tier_scope`, that scoped run produces only in-scope files, that existing out-of-scope files are deleted.
- Update test: assert scope args propagate to all stages (reuse the existing test override pattern if present).
- Safety rail test: dirty working tree aborts without `--force`; passes with it.

**Success criteria:**
- [ ] `mix ccxt_extract.pipeline --tier1 --skip-setup`-style smoke works (requires existing discoveries)
- [ ] After scoped run, `ls priv/output/*.json | wc -l` matches scope size
- [ ] `_manifest.json` has `tier_scope` field
- [ ] Safety rail aborts on dirty tree, proceeds with `--force`
- [ ] All quality gates green

**Files touched:** 3 lib files + tests.

---

### Task 3: Contract test scope-aware loading ⬜ (partial)

**Status:** Partial — load-time scoping and scoped `exchanges_checked` shipped
in the preflight patch (`CcxtExtract.ContractTest.run_all/1` now takes
`:exchanges`; the task loads only in-scope files and emits a non-fatal note
for missing ones). Remaining work is **ready** (Task 1 foundation landed):
migrate to `Scope.resolve/2` and add strict "universe mismatch" failure when
no scope flag is set but files are missing.
**Score:** [D:1/B:3/U:4 → Eff:3.5] 🎯 (scope down from original after preflight)

Preflight already addressed: load-time filtering, `summary.exchanges_checked`
accuracy, missing-file warning path, `--tier1` variant/alias expansion via
`Tiers.members_for_tier/1`. Task 3 now only needs the shared `Scope.resolve/2`
plumbing and the strict-universe guard.

**`lib/mix/tasks/ccxt_extract.contract_test.ex`:**
- Replace existing tier-flag logic with `Scope.resolve/2`.
- Only load in-scope JSON files from the output directory.
- When scope is `:all` but files are missing, fail with a clear message (likely means user ran a scoped extract first and forgot `--all`).
- Keep the existing report structure; update `exchanges_checked` count to reflect actual scope.

**Tests:** Update existing contract_test tests to exercise scoped loads.

**Success criteria:**
- [ ] `mix ccxt_extract.contract_test --tier1` reads exactly 5 files
- [ ] `mix ccxt_extract.contract_test --exchange binance` reads 1 file
- [ ] `mix ccxt_extract.contract_test` (no flags) reads whatever is on disk, fails loudly if the universe doesn't match exchanges.json

**Files touched:** 1 lib file + test.

---

### Task 4: QuickBEAM extractors scope flags ⬜

**Status:** Pending — **ready** (Task 1 foundation landed)
**Score:** [D:3/B:6/U:6 → Eff:2.0] 🎯

Three QuickBEAM extractors currently ignore scope (`load_markets` already has tier flags — audit it against the new `Scope.resolve/2` pattern and migrate for consistency).

**Tasks to update:**
- `ccxt_extract.describe` — per-exchange output under `priv/discoveries/describe/<id>.json` + `_manifest.json`
- `ccxt_extract.url_templates` — aggregate at `priv/discoveries/url_templates.json`
- `ccxt_extract.signing_fixtures` — per-exchange files
- `ccxt_extract.load_markets` — already filters; migrate to `Scope.resolve/2`

**Pattern:**
1. Add scope switches.
2. Call `Scope.resolve/2` on the universe list (from `priv/discoveries/exchanges.json`).
3. For aggregate writers: load existing aggregate, merge in-scope updates, rewrite. This makes successive scoped runs accumulate while a `--all` run produces a clean full file.
4. **Recompute envelope totals** (`count`, `total_*`, `with_*`, etc.) from the final merged entry list on every write — never carry them over from the loaded aggregate. Today's failing cached tests (`parse_methods` 1564 vs 1541, `ws_methods` 1574 vs 1539, `overrides` 100 vs 99) are exactly this class of drift.
5. For per-exchange writers: just write the in-scope set. Rely on orchestrator-level cleanup.

**Tests:** Per task, verify scope filters both read and write. Aggregate merge tested explicitly, including an assertion that envelope totals match the recomputed sum/count over merged entries (regression guard for today's drift failures).

**Success criteria:**
- [ ] Each task accepts full scope flag set
- [ ] Aggregate files merge correctly across scoped runs
- [ ] Envelope totals always equal the sum/count derived from the entry list (no drift)
- [ ] Per-exchange files align with scope

**Files touched:** 4 task files + tests.

---

### Task 5: OXC extractors scope flags — batch A ⬜

**Status:** Pending — **ready** (Task 1 foundation landed)
**Score:** [D:4/B:6/U:6 → Eff:1.5] 🚀

Six OXC AST extractors. All write aggregate JSON files under `priv/discoveries/`. Pattern is mechanical — establish once in the first task, reuse.

**Tasks:**
- `ccxt_extract.classes` → `class_hierarchy.json`
- `ccxt_extract.methods` → `methods_rest.json`, `methods_ws.json`
- `ccxt_extract.sign_methods` → `sign_methods.json`
- `ccxt_extract.handle_errors` → `handle_errors.json`
- `ccxt_extract.parse_methods` → `parse_methods.json`
- `ccxt_extract.ws_methods` → `ws_methods.json`

**Pattern:** Same as Task 4 aggregate writer (load existing, merge, rewrite, **recompute envelope totals from merged entries**).

Note: `parse_methods.json` and `ws_methods.json` are the two files whose envelope/entry drift is currently red in the cached tests — landing this task with the recompute step fixes them by construction (pending regeneration).

**Success criteria:**
- [ ] Each task accepts full scope flag set and filters iteration
- [ ] Aggregate merge preserves out-of-scope data when not running `--all`
- [ ] Envelope totals recomputed from merged entries (no drift)
- [ ] Tests updated (include drift regression assertion for parse_methods + ws_methods)

**Files touched:** 6 task files + tests.

---

### Task 6: OXC extractors scope flags — batch B ⬜

**Status:** Pending — **blocked by Task 5**
**Score:** [D:4/B:6/U:6 → Eff:1.5] 🚀

Remaining five OXC extractors. Same pattern.

**Tasks:**
- `ccxt_extract.interface_signatures` → `interface_signatures.json`
- `ccxt_extract.pagination` → `pagination.json`
- `ccxt_extract.unified_endpoints` → `unified_endpoints.json`
- `ccxt_extract.overrides` → `overrides.json`
- `ccxt_extract.base_methods` → `_base_methods.json`

**Success criteria:** same shape as Task 5. `overrides.json` is one of today's drift-failing files (`total_overrides` 100 vs 99) — the recompute step closes it.

**Files touched:** 5 task files + tests.

---

### Task 7: Analytics scope flags ⬜

**Status:** Pending — **blocked by Task 2** (needs scoped pipeline output)
**Score:** [D:3/B:5/U:5 → Eff:1.67] 🚀

Eight analytics tasks. Some may be natural no-ops if they already read
`priv/output/` (which is scoped after Task 2) — verify per-task.

**Tasks:**
- `ccxt_extract.summary` → `exchange_summary.json`
- `ccxt_extract.coverage` → `coverage_report.json`
- `ccxt_extract.method_analysis` → `method_analysis.json`
- `ccxt_extract.public_exchanges` → `public_exchanges.json`
- `ccxt_extract.validate_markets` → `market_validation.json`
- `ccxt_extract.family_analysis` → `family_analysis.json`
- `ccxt_extract.describe_keys` → `describe_keys.json`
- `ccxt_extract.describe_key_analysis` → `describe_key_analysis.json`

**Pattern:** For each task, decide:
- If it reads `priv/output/`: already scoped implicitly (just add flags for consistency and log the active scope).
- If it reads `priv/discoveries/` aggregates: filter by scope before computing.
- If it uses QuickBEAM runtime: scope the runtime exchange list.

**Success criteria:**
- [ ] Each task accepts scope flag set
- [ ] Output reflects scope (or is universe-wide where that makes sense, documented)
- [ ] Tests updated

**Files touched:** 8 task files + tests.

---

### Task 8: Documentation overhaul ⬜

**Status:** Pending — **blocked by Tasks 1–7**
**Score:** [D:2/B:7/U:8 → Eff:3.75] 🎯

Update every doc that talks about scope, the One Rule, or pipeline behavior.

**Files:**
- `CLAUDE.md` — rewrite "Tier-Based Scoping" section. Clarify the new scope rules (per-exchange filtering is now allowed; per-field is still forbidden). Add `--exchange` examples. Remove "Pipeline assembly, validate, and OXC-based extractors always run on all 111 exchanges" claim.
- `SCHEMA.md` — document `tier_scope` field in `_manifest.json` with example values.
- `README.md` — update usage section if it assumes all-111 output.
- `CHANGELOG.md` — add entry under `## [Unreleased]`: what changed, why, breaking changes for consumers.
- `ROADMAP.md` — link to this file for tracking; mark the refactor as in-progress then complete.

**Also update:**
- `SCOPED-EXTRACTION-TASKS.md` (this file) — mark all tasks complete, add "Archived" banner with link to CHANGELOG entry.

**Success criteria:**
- [ ] No stale claims about always-all-111 remain anywhere in the repo
- [ ] `grep -r "Never filter" --include=*.md` reflects the new nuance (per-exchange field extraction only)
- [ ] CHANGELOG entry is honest about the consumer-contract shift

**Files touched:** 6 docs.

---

### Task 9: Full verification sweep ⬜

**Status:** Pending — **blocked by Task 8**
**Score:** [D:2/B:6/U:7 → Eff:3.25] 🎯

Run all verification scenarios from the plan and fix anything that breaks.
This is the honest acceptance test — not "looks right" but "does right."

**Scenarios (from plan):**
1. Clean state test — `--tier1` produces exactly the 5 tier1 JSONs, deletes others.
2. `_manifest.json` `tier_scope` field reflects the active scope.
3. Aggregate filtering — `methods_rest.json` has 5 keys, not 111.
4. Safety rail aborts on dirty tree, proceeds with `--force`.
5. Idempotency — `--all` after `--tier1` reproduces all 111 JSONs.
6. Combinable flags — `--tier1 --dex` = 9.
7. Single-exchange — `--exchange binance` = 1; repeat/comma work.
8. Typo rejection — unknown exchange aborts with suggestions.
9. Mixed scope — `--tier1 --exchange hyperliquid` = 6.
10. `--all` conflict — combined with any narrow flag aborts.
11. Contract test honors scope.

**Quality gates:**
- [ ] `mix format`
- [ ] `mix credo --strict --format json` — 0 issues
- [ ] `mix dialyzer.json --quiet` — 0 warnings
- [ ] `mix test.json --quiet` — all pass

**Files touched:** likely small fix-up edits across the board.

---

### Task 10: Pipeline safety rail (direct invocation) ⬜

**Status:** Pending — captured from Task 2 Codex review.
**Score:** [D:2/B:4/U:3 → Eff:1.75] 🚀

The git-status safety rail added in Task 2 lives in
`mix ccxt_extract.update` only. Direct `mix ccxt_extract.pipeline --tier1`
invocations still call `ScopeCleanup.prune_out_of_scope/3` without a
dirty-tree check, so a power-user workflow can silently delete
uncommitted output JSON. Low-probability (power users know they're
pruning) but cheap to close.

**What to add:**
- `--force` switch on `Mix.Tasks.CcxtExtract.Pipeline`.
- Safety check that runs only when scope is narrowed (full-universe
  writes don't prune). Uses `ScopeCleanup.git_status_clean?/1` on the
  output directory, same pattern as `update.ex`.
- Test-override for `safety_paths` (mirror update.ex convention).
- Aborts on dirty tree; `--force` bypasses.

**Tests:** Dirty sandbox aborts without `--force`; proceeds with it;
full-universe run skips the check even on a dirty tree.

**Success criteria:**
- [ ] Direct `mix ccxt_extract.pipeline --tier1` aborts when
      `priv/output/` has uncommitted changes
- [ ] `--force` bypasses the rail
- [ ] `--all` / no scope flag skips the check (no prune happens)
- [ ] Moduledoc caveat in `ccxt_extract.pipeline.ex` can be dropped
      once the rail is in place

**Files touched:** 1 task file + test + small helper section.

---

## Task Graph

```
Task 1 ─┬─▶ Task 2 ─┬─▶ Task 7 ──┐
        │           │            │
        ├─▶ Task 3 ─┤            │
        │           │            │
        ├─▶ Task 4 ─┤            │
        │           │            │
        └─▶ Task 5 ─▶ Task 6 ────┤
                                  ├─▶ Task 8 ─▶ Task 9
                                  │
                     (docs wait for all code tasks)
```

Tasks 2, 3, 4, 5 can all start once Task 1 lands and run in parallel across sessions if desired (mark with `[P]` in status when claimed).

## Notes for future sessions

- **Always start** by reading this file, then reading `~/.claude/plans/breezy-wandering-sloth.md` for the full design.
- **One session, one task.** If a task feels too big partway through, split it and update this file rather than sprawling.
- **Tests are not optional.** The Scope module in particular is load-bearing — any regression there cascades.
- **Commit per task.** One task = one atomic commit (or small series). Reference this file's task number in commit messages.
