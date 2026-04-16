# Refactor Plan

Structural debt identified during end-to-end codebase review (2026-04-16).
Quick wins (items 4-6) shipped same session; items 1-3 below are multi-session
refactors requiring isolation and verification checkpoints.

**Dependency order:** Items 1, 2, 3, 7, 8, and 8b are shipped. Item 6
remains as the last independent candidate.

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

## ~~Item 7: Centralize QuickBEAM JS helpers~~ ✅

**D: 2 / B: 3 — ROI: 1.50** — **SHIPPED 2026-04-16**

Added `CcxtExtract.QuickbeamRuntime.install_extraction_helpers/1` — a single
installer that defines three shared JS globals: `getNonAliasIds()`,
`_errorNameMap`, and `_prepare()`. The helpers now live as module attributes
in `quickbeam_runtime.ex` and are installed by 6 extractors
(`describe`, `load_markets`, `url_templates`, `signing_fixtures`,
`describe_keys`, plus the internal id-listing runtime). Bundle load was
already centralized in `start/1` — this refactor targeted the JS helpers
baked into each module's `@js_setup`.

Dedup footprint: removed 4 copies of `getNonAliasIds`, 2 copies of
`_errorNameMap`, and 2 copies of the local `prepare()` walker (now a single
`globalThis._prepare` with defensive `_errorNameMap` lookup).
`describe_keys.ex` dropped its inline alias filter to call shared
`getNonAliasIds()`. `exchanges.ex` kept its inline filter — different
semantics (includes aliases), not worth a one-consumer shared helper.

Output byte-identical to pre-refactor (verified via scoped re-extraction of
`binance`, `kraken`, `deribit` — zero diffs modulo `extracted_at`).
3 new installer tests added in `test/ccxt_extract/quickbeam_runtime_test.exs`.

`QuickBEAM.Pool` deliberately **not** introduced — single Mix-task process
lifetime means pooling doesn't amortize bundle reloads. Revisit if a
long-lived consumer (LiveView dashboard, etc.) ever needs the extractor.

---

## ~~Item 8: Promote `read_json/1` to `CcxtExtract.JsonIO`~~ ✅

**D: 1 / B: 2 — ROI: 2.00** — **SHIPPED 2026-04-16**

Promoted Shape C (safest, from `DiscoveryLoader`) into a new
`CcxtExtract.JsonIO` module — `File.read` + try/rescue `Jason.DecodeError`,
returns `{:ok, decoded}`, `{:error, {:missing_input, path}}` (bare path,
preserves Shape A/B pattern matches), or `{:error, {:invalid_json, detail}}`.
Deleted all 7 duplicate copies. Two call sites that previously raised
`Jason.DecodeError` on corrupt input gained explicit `:invalid_json` arms:
`public_exchanges.load_exchange_describe/2` raises with a cleaner message,
`family_analysis.diff_describe_for_pair/3` logs a warning and returns `[]`.
`coverage_report.ex`'s five `{:error, _}` catch-alls now degrade gracefully
on corrupt coverage inputs — conscious decision, coverage report is
best-effort. `test/ccxt_extract/json_io_test.exs` covers all three shapes.
Full suite: 1579 passed, 0 failed.

## ~~Item 8b: Migrate remaining inline `File.read` + `Jason.decode` sites to `JsonIO`~~ ✅

**D: 2 / B: 2 — ROI: 1.00** — **SHIPPED 2026-04-16**

Added `JsonIO.read_json!/1` — a one-line `File.read!` + `Jason.decode!` pipe
that preserves the standard Elixir exception types (`File.Error`,
`Jason.DecodeError`) rather than translating them into tuples. Migrated ~20
real `File.read` + `Jason.decode` call sites across 9 modules
(`validation.ex`, `market_validation.ex`, `contract_test.ex`, `aliases.ex`,
`fixture_parity.ex`, `override_registry.ex`, `handle_errors.ex`,
`signing_fixtures.ex`, `load_markets.ex`, `aggregate_writer.ex`,
`mix/tasks/ccxt_extract.update.ex`). Trivial bang-style sites became
`JsonIO.read_json!(path)` one-liners; sites with `{:error, _}` fallbacks
became `case JsonIO.read_json(path) do` blocks with explicit
`{:missing_input, _}` / `{:invalid_json, _}` arms; the 4 sites that needed
typed error handling (two `rescue Jason.DecodeError` blocks in
`validation.ex`, the `:enoent` instructional message in `contract_test.ex`,
and the non-map-vs-malformed distinction in `aggregate_writer.ex`) kept
their semantics via explicit error arms.

Collapsed `DiscoveryLoader.load_exchange_field/5` and `load_exchange_lookup/4`
into a shared `load_global_exchanges_file/5` helper that takes the
per-entry validator as a callback — the other 5 scaffolds have distinct
success-path shapes (fan-out, grouping keys, field-specific extraction) that
make a shared helper net-negative on clarity.

Resolved open questions from the Item 8 staged review:
- **POSIX reason not carried** — repo audit showed no consumer needs to
  disambiguate `:enoent` vs. `:eacces` (`contract_test.ex`'s custom enoent
  message is already covered by the `:missing_input` vs. `:invalid_json`
  split). `JsonIO` API stays small.
- **Only field+lookup consolidated** — the 7-scaffold shared helper was
  considered and rejected after analysis.

Out of scope (intentionally untouched): `tiers.ex:43, :58` (compile-time
stdlib `JSON.decode!` via `@external_resource`); QuickBEAM-response
`Jason.decode!` sites in `describe.ex`, `describe_keys.ex`,
`describe_key_analysis.ex`, `load_markets.ex:118/:251`,
`url_templates.ex:190/:209`, `exchanges.ex:64`, `signing_fixtures.ex:395/:421`
(decode JS runtime output, not files); `mix/tasks/ccxt_extract.setup.ex:112,
:252, :258` (npm `package.json` reads — third-party metadata, kept with
setup tooling).

Full suite: **1582 passed, 0 failed** (1579 baseline + 3 new `read_json!/1`
tests). Post-migration grep confirms no `File.read` + `Jason.decode` pairs
remain in `lib/` outside `json_io.ex` itself, the out-of-scope QuickBEAM and
setup.ex sites, and `tiers.ex`'s compile-time stdlib `JSON.decode!`.

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
