# Refactor Plan

Structural debt identified during end-to-end codebase review (2026-04-16).
Quick wins (items 4-6) shipped same session; items 1-3 below are multi-session
refactors requiring isolation and verification checkpoints.

**Dependency order:** Item 1 (DiscoveryLoader) should land before Item 3
(generic override merge) — 61b needs clean seams in pipeline.ex to wire into.
Item 2 (Schema.validate removal) is independent of both.

---

## Item 1: Extract DiscoveryLoader from pipeline.ex

**D: 3 / B: 5 — ROI: 1.67**

`pipeline.ex` is 1,126 lines doing two jobs: assembly logic (what data goes in
each field) and discovery-file I/O (loading, validating, integrity stats). The
`load_all_data` private function spawns 14 distinct file-loading paths.
`validate_exchange_lookup_entry` (lines 948–1034) is an 8-clause
filename-string-match forest. Adding one new extractor costs 5 edit sites.

### What to extract

Create `CcxtExtract.DiscoveryLoader` with:

- All `load_*` private functions from pipeline.ex
- `validate_exchange_lookup_entry` clause forest
- `validate_exchange_field_entry` helpers
- Integrity-stats accumulation (`missing_entries`, `corrupt_entries`,
  `orphan_entries`, `id_mismatch_entries`)
- `read_json/1` (shared with Pipeline — either move or promote to Paths)

Public API: `DiscoveryLoader.load_all!(dir, exchanges_json)` → returns the
`%{describe: ..., sign_methods: ..., ...}` data map + integrity stats.

### What stays in pipeline.ex

- `extract/1` (public API)
- `build_exchange_data/4` and all field-assembly helpers
- `write!/1`, `build_manifest/3`, `copy_schema!`, `copy_base_methods!`
- Parent-resolution helpers (`find_parent_exchange_id`, `get_parent_*`)

### Verification checkpoints

1. `mix test test/ccxt_extract/pipeline_test.exs` — all existing tests pass
2. `mix test test/integration/cached/pipeline_cached_test.exs` — cached
   integration path unchanged
3. `mix ccxt_extract.pipeline --tier1` — output JSON byte-identical to
   pre-refactor baseline (diff `priv/output/binance.json` etc.)
4. New `test/ccxt_extract/discovery_loader_test.exs` — unit tests for the
   loader in isolation (mock discovery files, test integrity stats, test
   corrupt-file handling without running full pipeline)

### Estimated scope

~400 lines move out of pipeline.ex; ~50 lines of new glue code. Pipeline.ex
drops to ~700 lines. DiscoveryLoader ~450 lines. Net: same LOC, better seams.

---

## Item 2: Remove Schema.validate/1 triple validation surface

**D: 2 / B: 4 — ROI: 2.00**

Three parallel validation surfaces check overlapping invariants:

1. `Schema.validate/1` — 889 lines of hand-rolled Elixir structural checks
2. `Validation.validate_schema/2` — runs the JSON Schema (`exchange_v1.json`)
3. `validate_exchange_lookup_entry` in pipeline.ex — per-file field checks

When they disagree, nothing is authoritative. Every schema change requires
updating all three.

### Plan

1. **Audit `Schema.validate/1` vs JSON Schema** — identify any checks in
   Schema.validate that the JSON Schema doesn't cover. Likely candidates:
   cross-field constraints (e.g., "if `pagination` is non-null, each entry
   must have `containing_method`"). Document the gap.

2. **Migrate uncovered checks** — either add them to the JSON Schema (if
   expressible in JSON Schema draft-07) or move them to ContractTest as
   cross-field invariants (where they belong).

3. **Gut `Schema.validate/1`** — keep only the 10-line key-presence check
   (`@required_top_keys`, `@required_exchange_keys`, etc.) as a fast pre-flight.
   Delete the 800+ lines of structural type checking that duplicates the
   JSON Schema.

4. **Route pipeline through `Validation.validate_schema/2`** — single
   validation surface for structural conformance.

### Verification checkpoints

1. Run `mix ccxt_extract.pipeline --tier1 --tier2 --dex` with only JSON Schema
   validation — confirm no new failures vs the dual-validation baseline
2. Any checks removed from Schema.validate that the JSON Schema can't express
   → must appear as new ContractTest invariants with passing baselines
3. `mix test` — all existing tests pass

### Risk

Low. Schema.validate is defense-in-depth that's drifting into a liability.
The JSON Schema is already authoritative for consumers (it ships in output/).

---

## Item 3: Implement generic override merge (Task 61b)

**D: 3 / B: 5 — ROI: 1.67**

**Blocked by:** Item 1 (DiscoveryLoader extraction) — strongly preferred so the
merge stage wires into clean pipeline seams rather than the current monolith.

Currently `resolve_auth_override/3` is the only override consumer. Thirteen of
14 override files pass `override_registry_valid` green while contributing
nothing to output. The contract-test invariant tests the loader, not the merge.

### Plan

1. **Add `OverrideRegistry.apply_all/2`** — takes an exchange map and an
   override list, applies each entry's `value` at its RFC 6901 `path` using
   `put_in/3` with JSON Pointer → Access path resolution.

2. **Wire into pipeline** — after `build_exchange_data` assembles the base map,
   call `OverrideRegistry.apply_all/2` as the final merge step. This replaces
   the narrow `resolve_auth_override/3` with the generic path.

3. **Add ContractTest invariant** — `override_paths_present_in_output`:
   for every override entry, verify the path exists in the final output and
   the value matches. This tests the merge, not just the loader.

4. **Remove `resolve_auth_override/3`** — dead code once the generic merge
   handles `/structure/authenticated_sections` along with everything else.

### Verification checkpoints

1. All 14 override files' entries appear in output JSON at their specified paths
2. `mix ccxt_extract.pipeline --tier1` — output changes only where overrides
   apply (diff shows override values replacing derived values)
3. New ContractTest invariant passes green
4. Existing `override_registry_valid` invariant still passes

### Design decisions for the implementer

- **Conflict resolution:** When an override path targets a field that
  derivation already populated, override wins (that's the point). But should
  the pipeline log a warning? Useful for drift detection but noisy.
- **Deep vs shallow apply:** `/structure/authenticated_sections` is a
  top-level replace. But `/structure/sign_method/params/0/name` would be a
  deep set. Does `apply_all` need to handle both? RFC 6901 says yes, but
  the current override files only use shallow paths. Start shallow, document
  the depth limitation, extend when a real override needs it.

---

## ~~Item 4: Fix red default test suite (cached-corpus contract drift)~~ ✅

**D: 2 / B: 5 — ROI: 2.50** — **SHIPPED 2026-04-16**

Fixed via Option 1: cached tests now read `tier_scope` from the discovery
envelope and adjust expected counts. `describe_key_analysis` and `describe_keys`
tests use `min_exchange_count/1` helper (90 for `"all"`, 10 for scoped).
`family_analysis` test filters `@multi_member_families` at runtime against
families present in the scoped data.

---

## Item 5: Fail before write in strict mode

**D: 2 / B: 4 — ROI: 2.00**

*Source: Codex reviewer (2026-04-16)*

`Pipeline.extract/1` records validation failures instead of rejecting output
(`pipeline.ex:67, :136`), and the Mix task writes files *before* checking
`has_issues` (`mix/tasks/ccxt_extract.pipeline.ex:76`). `mix ccxt_extract.update`
runs contract tests non-strict (`update.ex:119, :165`). For a repo whose product
is generated JSON, this is backwards — invalid output should never be written.

### Plan

1. Move `has_issues` check before `Pipeline.write!/1` in the Mix task
2. Add `--strict` flag (or make strict the default) that aborts on any
   validation finding
3. Make `mix ccxt_extract.update` respect the strictness setting

---

## Item 6: Isolate setup tests from developer checkout

**D: 3 / B: 3 — ROI: 1.00**

*Source: Codex reviewer (2026-04-16)*

`mix ccxt_extract.setup` mutates the real `priv/ccxt` repo and local
`node_modules` (`setup.ex:45, :158`). The setup integration test restores state
by rewriting real files and checking out git refs in place
(`mix_tasks_integration_test.exs:92`). This will keep causing local-env and CI
pain.

### Plan

Use a temporary directory for setup integration tests instead of mutating the
developer's checkout. The test should clone/copy into `tmp_dir`, run setup
there, and verify. Current approach is fragile and non-hermetic.

---

## Item 7: Centralize QuickBEAM runtime initialization

**D: 2 / B: 3 — ROI: 1.50**

*Source: Codex reviewer (2026-04-16)*

Every runtime reloads the full CCXT bundle (`quickbeam_runtime.ex:45`). Similar
embedded JS setup is duplicated across `exchanges.ex:17`, `describe.ex:23`, and
`load_markets.ex:35`. `load_markets` can allocate five 1GB runtimes
simultaneously (`load_markets.ex:29`).

### Plan

Extract shared QuickBEAM JS helpers into a central module. Consider a runtime
pool or singleton for the bundle load, especially if `load_markets` parallelism
stays at 5 concurrent runtimes.

---

## Deferred Items (shipped or low-priority)

### Shipped same session (2026-04-16)

- **Rescue `OverrideRegistry.load/1` in `resolve_auth_override`** — one bad
  override file no longer aborts all 110 exchanges
- **Deduplicate `type_name/1`** — shared via `Schema.type_name/1`, deleted
  from pipeline.ex
- **Compile-guard `Tiers`** — actionable error when `class_hierarchy.json`
  missing at compile time

### Deferred

- **Drop `String.t() | keyword()` overload from `OXCExtractor.write!/2`** —
  requires updating 6 integration tests. Mechanical but touches many files;
  do when next touching integration test infra. D: 1 / B: 2.
- **Known-findings baseline for ContractTest** — Tasks 57c/57d have specific
  resolution plans that will eliminate the noise. Adding a suppression
  mechanism is complexity for a temporary problem. Revisit if 57c/57d slip
  past Phase 10. D: 2 / B: 3.
