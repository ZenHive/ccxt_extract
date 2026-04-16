# Refactor Plan

Structural debt identified during end-to-end codebase review (2026-04-16).
Quick wins (items 4-6) shipped same session; items 1-3 below are multi-session
refactors requiring isolation and verification checkpoints.

**Dependency order:** Items 1, 2, 3, 6, 7, 8, 8b, and 9 are all shipped. No
remaining independent candidates.

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

## ~~Item 6: Isolate setup tests from developer checkout~~ ✅

**D: 3 / B: 3 — ROI: 1.00** — **SHIPPED 2026-04-16**

*Source: Codex reviewer (2026-04-16)*

Added `:priv_dir_override` application env seam in
`CcxtExtract.Paths.priv_dir/0` — one override redirects all six `priv/`
accessors. Rewrote `describe "mix ccxt_extract.setup"` in
`test/integration/mix_tasks_integration_test.exs` to stage a faithful mirror
per test: `git clone --local --no-hardlinks priv/ccxt` into
`tmp_dir/priv/ccxt`, `File.cp_r!` `node_modules/ccxt` into
`tmp_dir/node_modules/ccxt`, point `:priv_dir_override` at `tmp_dir/priv`,
and wrap `Setup.run/1` in `File.cd!(tmp_dir, ...)` so relative
`node_modules/...` paths resolve inside the clone. Deleted the old
snapshot/restore block that rewrote real files and re-checked-out git refs
in place.

Dropped the `--latest` test — that branch fatals when the npm registry has
advanced past the developer's `priv/ccxt` tag (legitimate production guard,
untestable in isolation without stubbing npm or git). `--ccxt-version
CURRENT` covers structurally-equivalent update branches.

Isolation verified: before/after the suite, `priv/ccxt` HEAD and the
shasums of `priv/ccxt_version.json`, `priv/ccxt_bundle.js`, and
`node_modules/ccxt/package.json` are byte-identical. Interrupted runs no
longer leave the checkout on a detached HEAD. Full default suite: **1584
passed**; integration suite: **7 passed** in ~50s.

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

## ~~Item 9: Split read vs write paths in `CcxtExtract.Paths`~~ ✅

**D: 3 / B: 4 — ROI: 1.33** — **SHIPPED 2026-04-17**

Natural follow-up to Item 6. Item 6 introduced `:priv_dir_override` as a
single seam that redirected both reads and writes to a tmp dir — fine for
the setup test that staged a full CCXT clone, but heavy for the 12 other
integration tests that only need write isolation (they'd still rather read
the committed corpus).

Added a narrower `:priv_write_override` seam + `Paths.out/1` and
`Paths.out_priv_dir/0`. Writes resolve through `:priv_write_override` first,
then fall through to `:priv_dir_override`, then `:code.priv_dir/1`. Reads
continue through `Paths.priv/1`. Migrated 22 library modules + 4 mix tasks
from `Paths.priv(...)` to `Paths.out(...)` at every write site.

New `CcxtExtract.PrivWriteCase` (`test/support/priv_write_case.ex`) ExUnit
case template assigns `:priv_write_override` to a per-test tmp dir and
restores prior env on exit. Enforces `async: false` (the env is VM-global).
Adopted by 12 integration test modules and the analytics-scope-flags test.
Rewrote `test/mix/tasks/error_path_test.exs` — replaced the rename/restore
trick (that created `.bak` files in `priv/discoveries/`) with a tmp-dir
`:priv_dir_override`. No more risk of stranded backups on a crashed run.

**Breaking change to `mix ccxt_extract.update --output DIR`.** Previously
forwarded `--output` to each sub-stage, placing per-exchange JSON directly
at `<DIR>/`. Now sets `:priv_dir_override` at the update level via a
`with_priv_override/2` wrapper so every `Paths.priv/1` and `Paths.out/1`
in any sub-stage lands under `DIR`. Sub-stages no longer receive `--output`.
Final per-exchange JSON now lands at `<DIR>/output/` (was `<DIR>/`);
intermediates land at `<DIR>/discoveries/`. The git-safety-rail is skipped
under `--output` because external target dirs are not expected to be git
repos. Safety-rail paths moved from `@safety_paths` module attribute to a
computed function so overrides correctly isolate the rail in tests.

**Downstream follow-up required** — `ccxt_client/lib/ccxt/spec.ex:26`
reads specs from `priv/specs/json/<id>.json` (flat); after this change
`mix ccxt_extract.update --output ../ccxt_client/priv/specs/json` writes
them to `priv/specs/json/output/<id>.json`. Update the client's
`@spec_dir` to `"priv/specs/json/output"` and relocate the 23 committed
specs in a ccxt_client-side commit.

Full suite: **all passed** (compile clean, `update_test.exs`: 23/23).

---

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
