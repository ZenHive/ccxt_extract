# Scoped Extraction Refactor — Session Task Breakdown

> **Full design:** `~/.claude/plans/breezy-wandering-sloth.md` (referenced once, then forget).
> Each task below is sized for a single Claude Code session and produces working,
> committable code. Tasks are intentionally ordered by dependency — later tasks
> assume earlier ones are done.

## Vision

Tier flags (`--tier1/--tier2/--tier3/--dex`) and `--exchange <id>` scope the
**entire** extraction pipeline, not just the slow network stage. Default is
still all 110 exchanges (explicit `--all` or no scope flag). Out-of-scope
per-exchange files are deleted; aggregate discovery files are rewritten
with only in-scope keys. A git-status safety rail prevents accidental loss
of uncommitted work.

## New rule (replaces current "Tier-Based Scoping" in CLAUDE.md)

> The One Rule (**Extract EVERYTHING. Never filter.**) applies *per-exchange*
> — every field, every method, every AST node is extracted for every
> in-scope exchange. **Which exchanges are in scope** is controlled by
> scope flags (`--tier*`, `--exchange`, `--all`). Default is all 110.

---

## 🎯 Current Focus

**Post-refactor fix: scope-aware cached integration tests.** Committed
fixtures under `priv/discoveries/` are now generated under a scoped
extraction (~34–44 exchanges). 16 cached-test assertions hardcoded
full-universe thresholds (90+/100+/1400+) and failed. Fix dispatches on
**observed counts** rather than envelope `tier_scope` stamps, because:
(a) most fixtures have **no** `tier_scope` field, and (b)
`method_analysis.json` / `public_exchanges.json` stamp `"all"` even under
scoped runs — stamp cannot be trusted. Nine test files updated
(`describe_cached`, `handle_errors_cached`, `sign_methods_cached`,
`ws_methods_cached`, `overrides_cached`, `parse_methods_cached`,
`coverage_report_cached`, `method_analysis_integration`,
`public_exchanges_integration`). Each gained a `defp
min_exchange_count/1` returning the original full-universe threshold
when `count ≥ cutoff`, else a ~30% proportional floor. Ratio-style
assertions became `round(count * 0.75)` percentages. Post-review: the
per-file helpers were consolidated into
`CcxtExtract.Test.ScopeThresholds` (`test/support/scope_thresholds.ex`)
and a latent cutoff/floor gap was closed (observations in `[90, 99]` no
longer fail the strict branch). See [CHANGELOG.md](CHANGELOG.md)
Unreleased. **Followup tracked as [Task 13](#task-13-universal-envelope-tier_scope-stamping-followup)**:
stamp `tier_scope` into all aggregate envelopes via `AggregateWriter` so
tests can dispatch on the envelope rather than observed count.

**Task 6 landed.** Four remaining OXC-backed tasks (`interface_signatures`,
`pagination`, `unified_endpoints`, `overrides`) now accept the canonical
scope flag set via `TaskScope.parse_and_resolve!/3`. Three of the four
core modules already inherited from `OXCExtractor` (aggregate write was
already merge-safe); `Overrides` had a hand-rolled `write!` that now
routes through `AggregateWriter` with a private `write_stats/1`
callback. Envelope totals for `overrides.json` (`with_overrides`,
`total_overrides`, `total_new_methods`) are recomputed from merged
entries on every write — drift-bug class closed by construction.
`base_methods` is intentionally excluded: single-file base/Exchange.ts
parse, no per-exchange dimension, honesty-rule violation to accept
flags that do nothing. **New follow-up captured:** orchestrator
`run_oxc_extractors/0` at `update.ex:274` passes `[]` — direct invocation
honors scope, orchestrated invocation drops it (Task 11).

**Task 4 landed.** All four QuickBEAM-backed extractor tasks (`describe`,
`url_templates`, `signing_fixtures`, `load_markets`) accept the canonical
scope flag set via `CcxtExtract.TaskScope`. `url_templates` routes
aggregate writes through `AggregateWriter`; the three per-exchange-dir
tasks rebuild their manifest from disk via the new
`TaskScope.rebuild_manifest_exchanges/1` helper (count can never drift
from on-disk reality). `load_markets` switched from `--exchanges <csv>`
to canonical `--exchange` (repeatable) + `--all`; the translator shim in
`update.ex` is gone.

**Task 3 landed.** `mix ccxt_extract.contract_test` now goes through the
shared `CcxtExtract.TaskScope` and enforces a universe-mismatch guard
on no-flag / `--all` runs.

**Task 5 (prior).** Six OXC extractors are scope-aware end-to-end
(`classes`, `methods`, `sign_methods`, `handle_errors`, `parse_methods`,
`ws_methods`). `CcxtExtract.AggregateWriter` routes every aggregate
write through a merge-safe path that recomputes envelope totals from
merged entries on every write. `CcxtExtract.TaskScope` factors the
load-universe + scope-resolve plumbing shared across extractor tasks.
`classes` intentionally ignores scope for the data itself (hierarchy is
load-bearing for `Tiers` family inheritance) and only stamps
`tier_scope`. `handle_errors` fails loudly when a scoped run is missing
a required `priv/discoveries/describe/<id>.json`.

**Task 11 landed.** `mix ccxt_extract.update` now threads `scope_args(opts)`
into the OXC stage via `run_oxc_extractors/1`. `ccxt_extract.base_methods`
is excluded via `@unscoped_oxc_extractors` (single-file parse, no
per-exchange dimension — Honesty Rule).

**Task 7 landed.** Eight analytics tasks (`summary`, `coverage`,
`method_analysis`, `public_exchanges`, `validate_markets`,
`family_analysis`, `describe_keys`, `describe_key_analysis`) accept the
canonical scope flag set; `validate_markets` migrated from legacy
`--exchanges <csv>` to canonical `--exchange ID` (repeatable);
`run_analytics/1` in `update.ex` threads scope into both QuickBEAM and
derived loops. All scope-aware — no `:unscoped` carve-out.

**Task 8 landed.** Closes the docs drift between the landed scope-refactor
behavior (Tasks 1–7, 11) and the narrative in `CLAUDE.md`, `SCHEMA.md`,
`README.md`, `ROADMAP.md`. The One Rule gains a per-exchange/per-field
qualifier; `_manifest.json`'s `tier_scope` field is now documented in
`SCHEMA.md`; the stale "OXC-based extractors are never filtered" claim in
`README.md` is rewritten to the correct parse-vs-output-merge framing;
`--exchange` examples and the `--force`-gated safety rail are documented
in both README and CLAUDE.md Development Commands. Docs-only; no code
changed. See [CHANGELOG.md](CHANGELOG.md#task-8-documentation-overhaul-for-scoped-extraction).

**Task 10 landed.** `mix ccxt_extract.pipeline` now ports the `--force`-gated
git-status safety rail from `update.ex`, with one deliberate divergence:
full-universe runs (`--all` or no scope flag) skip the check since they
overwrite without pruning. Both entry points (orchestrator + direct
pipeline) now honor the same dirty-tree invariant.

**Task 9 landed.** Full verification sweep complete — all 11 scenarios
pass. Live sandbox runs proved S1/S2/S5/S6/S7/S9; arg-parse runs proved
S8/S10; the 201-test scope-suite covered S3/S4/S11. No fix-up commits
required. Spec count divergences (S1=10 not 5, S6=14 not 9, S9=11 not
6) are family-inheritance expansion, documented in CHANGELOG.

**Task 12 landed (post-Task-11 regression).** A consumer running
`mix ccxt_extract.update --tier1 --tier2 --dex` surfaced a regression
Task 9's sweep missed: stage-3 `handle_errors` hard-aborted on missing
`describe/gateio.json` / `describe/huobi.json`, because family-inheritance
expansion pulls aliases into scope while the describe extractor skips
them (`!d.alias`). New `CcxtExtract.Aliases` module centralises alias
membership over `priv/discoveries/exchanges.json`; `TaskScope.scoped_ids_missing_file/3`
gained an `:exclude_aliases` opt that `handle_errors` now uses. Aligns
stage-3 guards with the `is_alias` → `"alias"` precedent in
`CoverageReport`. **Refactor complete: Tasks 1–12 all ✅.**

**Known drift (post-Task 101): resolved 2026-04-17.** The `parse_methods`
coverage threshold dip and the cached-fixture holdover both cleared via a
full-universe `mix ccxt_extract.update` — coverage rebounded to 100/107 and
`coverage_report_cached_test.exs:88` now passes. See
[CHANGELOG.md](CHANGELOG.md#task-101-fixture-refresh-for-oxc-07--quickbeam-010).

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

### Task 3: Contract test scope-aware loading ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-3-contract-test-scope-migration).
**Score:** [D:1/B:3/U:4 → Eff:3.5] 🎯

Migrated `mix ccxt_extract.contract_test` to `CcxtExtract.TaskScope` and
added a strict universe-mismatch guard for no-flag / `--all` runs.
Previously-silent subsets (user ran a scoped extract, then ran
contract_test without a flag) now fail loud with a remediation message.
13 tests total (6 adapted, 7 new).

**Known follow-up (not blocking):** `lib/mix/tasks/ccxt_extract.update.ex`
still has a `TODO(Task 3 in SCOPED-EXTRACTION-TASKS.md)` comment and a
`tier_scope_args/1` helper that should now use `scope_args/1` since
contract_test accepts the full scope flag set. Deferred because the
pre-commit hook pattern-flagged the removal of deferred-work phrases
inside the stale comment as introducing deferred work — cleanest to
handle as a standalone comment-removal commit rather than fight the
hook mid-Task-3.

---

### Task 4: QuickBEAM extractors scope flags ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-4-quickbeam-extractors-scope-flags).
**Score:** [D:3/B:6/U:6 → Eff:2.0] 🎯

All four QuickBEAM-backed tasks accept the canonical scope flag set via
`TaskScope`; `url_templates` routes through `AggregateWriter`; the three
per-exchange-directory tasks rebuild their manifests from disk via a new
`TaskScope.rebuild_manifest_exchanges/1` helper. `load_markets` migrated
to `--exchange` (repeatable) + `--all`, dropping the legacy
`--exchanges <csv>` flag. `update.ex` special-case translator and
Task-3-era `tier_scope_args` shim are removed.

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

### Task 5: OXC extractors scope flags — batch A ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-5-oxc-extractors-scope-flags--batch-a).
**Score:** [D:4/B:6/U:6 → Eff:1.5] 🚀

Six OXC AST extractors gained the full scope flag set
(`--tier1/--tier2/--tier3/--dex/--all/--exchange`). New
`CcxtExtract.AggregateWriter` module (plain functions, not a macro —
per Q1 at plan time) routes every aggregate write through a merge-safe
path that recomputes envelope totals from the final merged entries on
every write — drift-bug class closed by construction. New
`CcxtExtract.TaskScope` factors the load-universe + scope-resolve
plumbing shared across tasks; `pipeline.ex` now delegates.

**Per-task outcomes:**
- `ccxt_extract.classes` — scope flags accepted for consistency and
  stamped into `tier_scope`, but class list / `tree` / `ws_counterparts`
  always reflect the full CCXT source (per Q2: hierarchy is load-bearing
  for `Tiers` family inheritance; a partial tree would silently degrade
  tier expansion). Documented exception in the moduledoc.
- `ccxt_extract.methods` — scope flags alongside `--type rest|ws`;
  filters extract results, writes `methods_{rest,ws}.json` with
  `"type"` preserved via the new `:extra` envelope hook.
- `ccxt_extract.sign_methods` / `parse_methods` / `ws_methods` —
  inherit merge-safe behavior via the updated `OXCExtractor.write!`.
  `parse_methods` / `ws_methods` close the 1564 vs 1541 / 1574 vs 1539
  drift by construction (pending full regeneration).
- `ccxt_extract.handle_errors` — same inheritance plus a loud-fail
  guard: scoped runs missing `priv/discoveries/describe/<id>.json`
  abort with actionable instructions (`--all` tolerates gaps).

**Tests:**
- `test/ccxt_extract/aggregate_writer_test.exs` — 19 cases covering
  fresh write, `:all` overwrite, scoped MapSet merge, stats-recompute
  drift guard (assertion mirrors the existing cached-test shape),
  sort determinism, `tier_scope` stamping, malformed-file raises,
  AST normalization default-on behavior.
- `test/mix/tasks/oxc_scope_flags_test.exs` — 27 cases: argument
  parsing + `--all`-conflict / unknown-exchange error mapping across
  all six tasks; pure-function unit tests for
  `TaskScope.scoped_ids_missing_file/2` (the helper backing
  `handle_errors`' describe-guard).
- Cached integration tests for `parse_methods` / `ws_methods` remain
  red pending `mix ccxt_extract.update` regeneration; assertion style
  unchanged (stats will match entries post-regen).

**Files touched:** 2 new lib modules (`aggregate_writer.ex`,
`task_scope.ex`), 6 extractor task files, 4 core extractor modules
(`classes.ex`, `methods.ex`, `oxc_extractor.ex`, `handle_errors.ex`
moduledoc), `pipeline.ex` (delegates to TaskScope), 2 new test files.

**Follow-up fixes (code review).** Two bugs + two docs corrected post-landing:
`AggregateWriter` `:all` now skips the existing-file read (was raising on
corrupt aggregates despite "wholesale replace" contract); `TaskScope.load_universe`
re-sourced from `priv/ccxt/ts/src/*.ts` (was reading stale
`priv/discoveries/exchanges.json`, which rejected valid IDs like `coincatch`);
`AggregateWriter` `:scope` docstring documents the pre-filter contract;
`oxc_scope_flags_test.exs` moduledoc accurately states the `mix ccxt_extract.setup`
dependency for scope-resolution tests.

**Design decisions captured at plan time** (`~/.claude/plans/idempotent-discovering-toucan.md`):
- Q1: New module over macro extension — keeps merge logic in plain
  functions, usable by both OXCExtractor-inheriting tasks and the
  hand-rolled ones (`classes`, `methods`). Task 4 (QuickBEAM) will
  reuse it.
- Q2: `classes.ex` always parses all `.ts` files regardless of scope.
  `class_hierarchy.json` invariant; scope flags stamp `tier_scope`
  only. One documented exception to the Task 5 pattern.

---

### Task 6: OXC extractors scope flags — batch B ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-6-oxc-extractors-scope-flags--batch-b).
**Score:** [D:4/B:6/U:6 → Eff:1.5] 🚀

Four remaining OXC extractors now accept the canonical scope flag set
via `TaskScope.parse_and_resolve!/3`:

- `ccxt_extract.interface_signatures` → `interface_signatures.json`
- `ccxt_extract.pagination` → `pagination.json`
- `ccxt_extract.unified_endpoints` → `unified_endpoints.json`
- `ccxt_extract.overrides` → `overrides.json`

Three of the four already inherited from `OXCExtractor` (aggregate
write path already merge-safe); only the task files needed to filter
results and thread `scope`/`tier_scope`. `Overrides` had a hand-rolled
`write!` that was migrated to route through `AggregateWriter` with a
new private `write_stats/1` callback. Envelope totals for
`overrides.json` are now recomputed from merged entries on every write.

**`ccxt_extract.base_methods` intentionally excluded.** Single-file
base/Exchange.ts parse with no per-exchange dimension; `_base_methods.json`
is a flat map, not a list of exchange entries; `AggregateWriter` doesn't
apply. Accepting flags that do nothing would be a silent lie (Honesty
Rule in CLAUDE.md).

**Follow-up captured (Task 11).** During audit, discovered that
`mix ccxt_extract.update` → `run_oxc_extractors/0` at `update.ex:274`
passes `[]` to every OXC task — scope args from the orchestrator never
reach the OXC stage. Direct invocation honors scope; orchestrated
invocation silently drops it. Tracked below as Task 11.

---

### Task 11: Orchestrator scope-threading gap (OXC stage) ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-11-orchestrator-scope-threading-gap-oxc-stage).
**Score:** [D:1/B:4/U:4 → Eff:4.0] 🎯

`run_oxc_extractors/1` now takes `opts` and passes `scope_args(opts)` to
every scope-aware OXC task. `ccxt_extract.base_methods` is excluded via
a new `@unscoped_oxc_extractors` MapSet (single-file parse, no
per-exchange dimension — Honesty Rule). Added one scope-propagation
test in `update_test.exs` mirroring the existing pipeline/contract_test
assertion pattern.

---

### Task 12: Alias-aware scope guards (post-Task-11 regression) ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#unreleased).
**Score:** [D:2/B:7/U:8 → Eff:3.75] 🎯

**Problem.** `mix ccxt_extract.update --tier1 --tier2 --dex` raised in
stage 3 with `Missing describe files for scoped exchange(s): gateio.json,
huobi.json`. Root cause: `CcxtExtract.Tiers` expands families via
`class_hierarchy.json` and pulls in both variants *and* aliases, but the
QuickBEAM-backed extractors (`describe`, `url_templates`, `signing_fixtures`,
`load_markets`) skip aliases via a `!d.alias` filter in their JS runtime
enumeration. `TaskScope.scoped_ids_missing_file/2` had no alias awareness,
so `handle_errors` hard-aborted on legitimately absent files. Task 9's
verification sweep missed this because live sandbox runs redirected
output to `/tmp/...` and never exercised the full stage-3 path end-to-end.

**Fix.**

- New `CcxtExtract.Aliases` module (`lib/ccxt_extract/aliases.ex`) —
  single source of truth over `priv/discoveries/exchanges.json`. Exposes
  `alias_ids!/1`, `alias?/1`, `exclude_aliases/1`. Reads-only; producer
  stays in `CcxtExtract.Exchanges`.
- `TaskScope.scoped_ids_missing_file/3` gains `:exclude_aliases` opt
  (default `false`, preserves behaviour for all existing callers).
- `ccxt_extract.handle_errors` flips the opt on; moduledoc cites the
  `is_alias` → `"alias"` precedent in `CoverageReport`.
- `contract_test` callers audited: `priv/output/` writes alias entries
  (pipeline `deepExtend` merges produce 110 files from 110 TS sources),
  so those guards remain correct as-is.
- Regression tests: new `test/ccxt_extract/aliases_test.exs` (7 cases),
  `exclude_aliases: true` unit tests in `oxc_scope_flags_test.exs`, and
  a scoped-run assertion in `handle_errors_integration_test.exs` that
  uses `--exchange gate,gateio` to reproduce the exact asymmetry.

**Architectural alternatives rejected.** Filtering aliases in
`CcxtExtract.Tiers` would silently drop them from scoped method
inventories (classes, methods, sign_methods legitimately process alias
TS files), violating the "Extract EVERYTHING" per-exchange rule.
Re-detecting aliases from TS source at each call site duplicates the
canonical `!d.alias` runtime check — `exchanges.json` is the derived
artifact of that check, reusing it keeps a single source of truth.

---

### Task 13: Universal envelope `tier_scope` stamping (followup) 🔄 — split

**Split into 13a (code plumbing, ✅ shipped) and 13b (test migration, ⬜ open).**

### Task 13a: Code plumbing — aggregate writers stamp `tier_scope` ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-13a).
**Score:** [D:1/B:4/U:5 → Eff:4.5] 🎯

Three emitters previously missing a `tier_scope` stamp now carry one:

- `_base_methods.json` — `BaseMethods.write!/2` accepts a `:tier_scope`
  option defaulting to `"all"`. The file is universe-agnostic (parses
  the base `Exchange.ts` class that every exchange inherits), so `"all"`
  is semantically correct and not a placeholder.
- `_validation_report.json` — `Validation.validate_all/1` accepts a
  `:tier_scope` option; `Mix.Tasks.CcxtExtract.Validate` derives it by
  reading `_manifest.json` from the output directory, falling back to
  `"all"` when the manifest is absent or unstamped. Report envelope
  gains a top-level `tier_scope` field.
- `_contract_test_report.json` — `ContractTest.run_all/1` accepts a
  `:tier_scope` option; `Mix.Tasks.CcxtExtract.ContractTest` threads
  `CcxtExtract.Scope.to_manifest_value/1` output alongside the resolved
  `scope`. Report envelope gains a top-level `tier_scope` field.

**Not touched** — the two aggregates that already stamp correctly
through opts (`method_analysis.json`, `public_exchanges.json`). Their
apparent leak is stale committed fixtures, not code drift. Fresh runs
already produce accurate stamps.

### Task 13b: Test migration — envelope dispatch in cached tests ✅

**Status:** Complete — shipped 2026-05-08 via PR #5 (Cursor-delegated, INE-58). See [CHANGELOG.md](CHANGELOG.md).
**Score:** [D:2/B:3/U:3 → Eff:1.5] 🚀

Followup to the scope-refactor (Tasks 1–12) and the post-refactor
cached-test fix (CHANGELOG Unreleased). Currently, `AggregateWriter`
stamps `tier_scope` on most aggregate envelopes, but
`method_analysis.json` and `public_exchanges.json` stamp `"all"`
regardless of actual scope, and many cached fixtures don't stamp
`tier_scope` at all.

**Why.** Cached integration tests had to dispatch on **observed
exchange counts** as a workaround, via
`CcxtExtract.Test.ScopeThresholds` (`test/support/scope_thresholds.ex`).
Stamping `tier_scope` universally would let tests dispatch on the
envelope (stable, explicit) rather than observed count (brittle,
requires proportional floors and the magic ~30% fraction). Once landed,
the shared helper becomes thinner or unnecessary.

**Files likely touched:**
- `lib/ccxt_extract/aggregate_writer.ex` — ensure every aggregate write
  stamps the active scope.
- `lib/mix/tasks/ccxt_extract.method_analysis.ex` +
  `lib/ccxt_extract/method_analysis.ex` — stop hardcoding `"all"`.
- `lib/mix/tasks/ccxt_extract.public_exchanges.ex` +
  `lib/ccxt_extract/public_exchanges.ex` — same.
- Audit all aggregate-emitting tasks for missing stamps.
- `test/integration/` — migrate 9 cached tests from observed-count
  dispatch to envelope dispatch. Simplify or remove
  `test/support/scope_thresholds.ex`.

**Success criteria:**
- [x] Every aggregate `.json` under `priv/discoveries/` has an accurate
      `tier_scope` field matching the run that produced it.
- [x] Cached tests use envelope dispatch; scope thresholds helper
      retains only `full_universe?/1`, `corpus_full_universe?/0`, and
      the scope-independent `proportional/2`.
- [x] `aggregate_writer.ex` stamps `tier_scope` last so neither `:extra`
      nor `stats_fn` output can shadow it.

---

### Task 7: Analytics scope flags ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-7-analytics-scope-flags).
**Score:** [D:3/B:5/U:5 → Eff:1.67] 🚀

All eight analytics tasks now accept the canonical scope flag set via
`TaskScope.parse_and_resolve!/3`. Each output gains a top-level
`tier_scope` envelope stamp. Per-task notes:

- **Derived (6):** `summary`, `coverage`, `method_analysis`,
  `public_exchanges`, `validate_markets`, `family_analysis` — `extract/0`
  → `extract/1` taking a `scope` opt; `write!/2` migrated from positional
  `output_path` to a keyword `opts` list (`output_path`, `tier_scope`).
- **QuickBEAM (2):** `describe_keys`, `describe_key_analysis` — JS
  `extractDescribeKeys` / `extractNestingDepths` accept an optional
  `idFilter` array; only in-scope class IDs get instantiated.
- **`validate_markets` flag migration:** legacy `--exchanges <csv>`
  (spot-check sample selector) replaced by canonical `--exchange ID`
  (repeatable). When scope is narrowed, `--spot-check` covers exactly the
  in-scope set; without scope, falls back to the historical sample
  (binance, bybit, okx). Mirrors Task 4's `LoadMarkets` migration.
- **`family_analysis` semantics:** family kept iff scope intersects root,
  variants, or aliases. Within a kept family, ALL members analyzed —
  hierarchy stays universe-wide (Task 5 Q2 precedent).
- **Orchestrator threading.** `run_analytics/1` in `update.ex` threads
  `scope_args(opts)` into both QuickBEAM and derived analytic loops.
  Pre-Task-7 it passed `[]` (parallel to the Task 11 OXC gap). All eight
  are scope-aware — no `:unscoped` carve-out (Honesty Rule).

**Tests.** New `test/mix/tasks/analytics_scope_flags_test.exs` (mirrors
`oxc_scope_flags_test.exs`); new orchestrator-propagation test in
`update_test.exs`. All 138 affected unit tests + 100 affected integration
tests + 22 update-orchestrator tests pass. 0 dialyzer warnings. Credo
finds only pre-existing TODO tags.

**Unblocks Tasks 8 (docs overhaul) and 9 (full verification sweep).**

---

### Task 8: Documentation overhaul ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-8-documentation-overhaul-for-scoped-extraction).
**Score:** [D:2/B:7/U:8 → Eff:3.75] 🎯

Five docs updated to match landed scope-refactor behavior — CLAUDE.md
(One Rule qualifier, schema example bump to 1.8.0 with `exchange.tier`,
scope-flag examples + safety-rail note in Development Commands, stale
`(Tasks 6/7/8/9/10 remaining)` counter fixed), SCHEMA.md (`tier_scope`
row added to `_manifest.json` table), README.md (stale "never filtered"
claim corrected, `--exchange` + `--force` examples added), ROADMAP.md
(Current Focus §"Scope" paragraph links to this file and summarizes
remaining work), and this file (self-marked ✅). Docs-only; no `.ex`
changes, so `mix` quality gates untouched. Verification via
repo-wide grep for the retired stale phrases returns no live hits.

**Original spec (retained for traceability):**

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

### Task 9: Full verification sweep ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-9-full-verification-sweep).
**Score:** [D:2/B:6/U:7 → Eff:3.25] 🎯

All 11 scenarios verified. Live sandbox runs (`--output /tmp/...`) for
the user-visible scopes (S1, S2, S5, S6, S7, S9), live arg-parse runs
for error paths (S8, S10), and the 201-test scope-suite for invariants
that would have required mutating `priv/discoveries/` (S3, S4, S11).
No fix-up commits required — the design held. Spec count divergences
in S1/S6/S9 are family-inheritance expansion (documented in CHANGELOG),
not defects. Existing `_manifest.json` / `methods_rest.json` lack the
`tier_scope` stamp because they predate it; next `mix ccxt_extract.update`
will normalize.

**Original spec (retained for traceability):**

Run all verification scenarios from the plan and fix anything that breaks.
This is the honest acceptance test — not "looks right" but "does right."

**Scenarios (from plan):**
1. Clean state test — `--tier1` produces exactly the 5 tier1 JSONs, deletes others.
2. `_manifest.json` `tier_scope` field reflects the active scope.
3. Aggregate filtering — `methods_rest.json` has 5 keys, not 110.
4. Safety rail aborts on dirty tree, proceeds with `--force`.
5. Idempotency — `--all` after `--tier1` reproduces all 110 JSONs.
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

### Task 10: Pipeline safety rail (direct invocation) ✅

**Status:** Complete — see [CHANGELOG.md](CHANGELOG.md#task-10-pipeline-safety-rail-direct-invocation).
**Score:** [D:2/B:4/U:3 → Eff:1.75] 🚀

`mix ccxt_extract.pipeline` now mirrors the `--force`-gated git-status
safety rail from `update.ex`. One deliberate divergence: full-universe
runs (`--all` or no scope flag) skip the check, since they overwrite
without pruning — only narrowed scopes have something destructive to
gate. Three new tests (dirty+narrow aborts, `--force` bypasses, `--all`
skips). No shared safety-rail module: two callers, ~15 LOC each, per
the "no abstraction without 3+ use cases" rule.

**Original spec (retained for traceability):**

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
 ✅     │    ✅     │     ✅      │
        ├─▶ Task 3 ─┤             │
        │    ✅     │             │
        ├─▶ Task 4 ─┤             │
        │    ✅     │             │
        └─▶ Task 5 ─▶ Task 6 ─────┤
             ✅        ✅         ├─▶ Task 8 ─▶ Task 9 ─▶ Task 12
                                  │     ✅                 ✅
                                  │                 (post-sweep regression)
             Task 10 ✅            │
             Task 11 ✅            │
                     (docs wait for all code tasks)
```

Tasks 1–12 complete. Task 13 tracks one remaining followup surfaced
by the post-refactor cached-test fix: universal `tier_scope` envelope
stamping so tests dispatch on the envelope instead of observed counts.

## Notes for future sessions

- **Always start** by reading this file, then reading `~/.claude/plans/breezy-wandering-sloth.md` for the full design.
- **One session, one task.** If a task feels too big partway through, split it and update this file rather than sprawling.
- **Tests are not optional.** The Scope module in particular is load-bearing — any regression there cascades.
- **Commit per task.** One task = one atomic commit (or small series). Reference this file's task number in commit messages.
