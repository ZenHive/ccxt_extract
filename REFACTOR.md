# Refactor Plan

Structural debt identified during end-to-end codebase review (2026-04-16).
Quick wins (items 4-6) shipped same session; items 1-3 below are multi-session
refactors requiring isolation and verification checkpoints.

**Dependency order:** Items 1, 2, and 3 are shipped. Item 8 (below) is
independent and remains the next easy win.

---

## ~~Item 1: Extract DiscoveryLoader from pipeline.ex~~ ✅

**D: 3 / B: 5 — ROI: 1.67** — **SHIPPED 2026-04-16**

Extracted `CcxtExtract.DiscoveryLoader` — ~520 lines of discovery-file I/O,
validation, and integrity-stats accumulation moved out of pipeline.ex.
Pipeline dropped from 1,122 to 604 lines. Loader owns the full data map shape
including `canonical_has_keys`. Public API: `DiscoveryLoader.load_all!/2` and
`DiscoveryLoader.read_json/1`. 9 isolation tests added. Output byte-identical
to pre-refactor baseline (`extracted_at` timestamps aside).

---

## ~~Item 2: Remove Schema.validate/1 triple validation surface~~ ✅

**D: 2 / B: 4 — ROI: 2.00** — **SHIPPED 2026-04-16**

Gutted `Schema.validate/1` from 891 lines to ~50. Kept only key-presence
checks (`@required_top_keys` etc.) and `check_schema_version`. Removed 800+
lines of structural type checking that duplicated `exchange_v1.json` + JSV.
Removed 9 tests that asserted deep structural checks (now the JSON Schema's
job). `Validation.validate_schema/2` is the single authoritative validator.

---

## ~~Item 3: Implement generic override merge (Task 61b)~~ ✅

**D: 3 / B: 5 — ROI: 1.67** — **SHIPPED 2026-04-16**

Added `OverrideRegistry.apply_all/2` + public `pointer_to_keys/1` — a generic
RFC 6901 merge stage applied as the final step of `Pipeline.extract/1`.
Deleted `resolve_auth_override/3` (the narrow single-pointer consumer) and
its call site. 13 of 14 override files previously loaded green but contributed
nothing to output; all 14 now flow end-to-end. New ContractTest invariant
`override_paths_present_in_output` verifies every entry's `value` is
observable at its pointer path in emitted JSON — 0 findings baseline.
Added `priv/overrides/gateio.json` to replace the deleted parent-chain walk
(gateio was inheriting gate's override); no other exchange regressed.
Output byte-identical to pre-refactor baseline modulo `extracted_at` and
the legitimate gateio re-introduction. Shallow string-key pointers only;
numeric segments (array indices) raise loudly — `Access.at/1` support lands
when a real override file needs it.

---

## ~~Item 4: Fix red default test suite (cached-corpus contract drift)~~ ✅

**D: 2 / B: 5 — ROI: 2.50** — **SHIPPED 2026-04-16**

Fixed via Option 1: cached tests now read `tier_scope` from the discovery
envelope and adjust expected counts. `describe_key_analysis` and `describe_keys`
tests use `min_exchange_count/1` helper (90 for `"all"`, 10 for scoped).
`family_analysis` test filters `@multi_member_families` at runtime against
families present in the scoped data.

---

## ~~Item 5: Fail before write in strict mode~~ ✅

**D: 2 / B: 4 — ROI: 2.00** — **SHIPPED 2026-04-16**

*Source: Codex reviewer (2026-04-16)*

Reordered `Mix.Tasks.CcxtExtract.Pipeline.run/1`: `has_data_issues?(stats)` is
now checked BEFORE `Pipeline.write!/1` when `--strict` is set. Invalid output
is never written to disk in strict mode. Non-strict path unchanged. `update.ex`
inherits the fix via `Mix.Task.rerun` exception propagation.

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

## Item 8: Promote `read_json/1` to `CcxtExtract.Paths`

**D: 1 / B: 2 — ROI: 2.00**

`read_json/1` is duplicated across 7 modules: `discovery_loader.ex`,
`describe_key_analysis.ex`, `method_analysis.ex`, `summary.ex`,
`public_exchanges.ex`, `coverage_report.ex`, `family_analysis.ex`. The
copies are **not identical** — they split into three shapes:

- **Shape A (4 copies: `describe_key_analysis`, `summary`, `family_analysis`,
  `method_analysis`):** `File.exists?` + `File.read!` + `Jason.decode!` —
  returns `{:error, {:missing_input, path}}` or raises on invalid JSON.
- **Shape B (2 copies: `public_exchanges`, `coverage_report`):** `File.read`
  matched against `{:ok, _}` / `{:error, :enoent}` only — raises on invalid
  JSON, and other `File.read` errors (`:eacces`, `:eisdir`) crash the pattern.
- **Shape C (1 copy: `discovery_loader`):** `File.read` + try/rescue
  `Jason.DecodeError` — the only shape that returns
  `{:error, {:invalid_json, detail}}` instead of raising.

### Plan

Promote `DiscoveryLoader.read_json/1` (Shape C — the safest) to
`CcxtExtract.Paths.read_json/1` (or a new `CcxtExtract.JsonIO` module) and
delete the 6 other copies. This is a small **behavior upgrade**, not a
pure mechanical consolidation: callers currently on Shapes A/B will start
receiving `{:error, {:invalid_json, _}}` tuples instead of a raise.

Before merging the promotion, audit each consumer's call site to confirm
either (a) the new `:invalid_json` tuple falls through an existing
`{:error, _}` branch harmlessly, or (b) the call site needs an explicit
`:invalid_json` clause to preserve intent. Do this when next touching any
of the consumer modules so the cost is amortized.

### Verification

- `mix test --quiet` — all existing tests pass.
- `mix compile --warnings-as-errors` — no new warnings.
- Manually grep each `read_json` call site for `{:error, _}` handling and
  confirm the new `:invalid_json` branch is either handled or never
  reachable in practice (no global discovery file is ever malformed JSON
  in a green tree).

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
