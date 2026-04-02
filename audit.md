# Extraction Audit

**Purpose:** Find correctness bugs in the existing extraction pipeline before Phase 5 distribution and Phase 6 parity work make the JSON contract harder to change.

**Context from `ROADMAP.md`:** Phases 1-4 are complete. The highest-risk bugs are no longer "missing features" but silent data loss, nondeterministic output, source/runtime mismatches, and validator blind spots across QuickBEAM, OXC, pipeline assembly, and schema validation.

**Out of scope:** New product features from Tasks 25-37 unless they are required to expose or confirm an extraction bug. This document is for finding bugs in current extraction behavior, not for expanding the feature set.

## Audit Goals

- Prove whether current extraction output is complete, stable, and internally consistent.
- Find bugs that existing schema checks, coverage checks, and round-trip checks do not catch.
- Turn every confirmed bug into a regression test before or alongside the fix.
- Improve validators only when an audit demonstrates a real blind spot.

## Audit Outputs

- A reproducible finding for each confirmed bug.
- The smallest exchange set or fixture needed to reproduce it.
- A note about whether the current validator or coverage report caught it.
- A matching regression test in the appropriate unit, cached, or extraction tier.

## Entry Checks

- [ ] `mix test.json --quiet` passes on cached/unit tests before starting deeper audit work.
- [ ] `mix ccxt_extract.pipeline` succeeds against the current artifact set.
- [ ] `mix ccxt_extract.validate --strict` is run at least once to establish the current baseline.
- [ ] The audit uses tracked fixtures first, then targeted live extraction only where offline artifacts cannot answer the question.

## Quick Commands

```bash
mix test.json --quiet
mix test.json --quiet --include extraction
mix ccxt_extract.pipeline
mix ccxt_extract.validate --strict
mix ccxt_extract.coverage
mix ccxt_extract.validate_markets --spot-check
mix run examples/compare_old_specs.exs
mix run examples/compare_go_extractor.exs
```

## Required Exchange Matrix

Use a representative matrix instead of only "happy path" exchanges:

- Alias exchange
- Root REST exchange
- Derived REST exchange
- Root WS exchange
- Derived WS exchange
- DEX or wallet-auth exchange
- Exchange with `loadMarkets()` success
- Exchange with expected `loadMarkets()` auth or geo failure
- Exchange with empty or near-empty parse/ws/sign data
- Exchange with overrides on REST only and WS only

## Current Audit Tracks

| Task | Status | Notes |
|------|--------|-------|
| Audit 1 | ✅ | Complete — tracked fixtures clean for this scope; added orphan/id-mismatch detection and regression tests |
| Audit 2 | ⬜ | Determinism and reproducibility |
| Audit 3 `[P]` | ⬜ | QuickBEAM runtime extraction correctness |
| Audit 4 `[P]` | ⬜ | OXC structural extraction correctness |
| Audit 5 | ✅ | Complete — legitimate null reasons documented; corrupt global entries and partial structure maps no longer pass silently |
| Audit 6 | ⬜ | Round-trip validation blind spots |
| Audit 7 `[P]` | ⬜ | Coverage report consistency |
| Audit 8 `[P]` | ⬜ | External parity and omission checks |
| Audit 9 | ⬜ | Regression-test follow-through |

## Audit Tasks

- [x] **Audit 1: Manifest and artifact integrity** [D:2/B:9/U:9 → Eff:4.50] 🎯
  Verify that every manifest-listed file exists, decodes, and contains the expected exchange id. Detect orphan files, mismatched ids, and cases where a missing file becomes a legitimate-looking `null` in assembled output. Cover both per-exchange artifacts (`describe/`, `load_markets/`) and global discovery files.
  Success criteria:
  - [x] Missing, corrupt, orphan, and id-mismatch artifacts are reported separately.
  - [x] Alias exchanges are not misclassified as missing-data bugs.
  - [x] At least one injected bad-artifact scenario fails through existing or newly-added tests.

  Result:
  - No confirmed manifest/artifact integrity defects were found in the tracked fixture set for this scope.
  - The audit exposed a guard blind spot rather than a fixture bug: pipeline and validation reporting did not previously detect orphan artifacts or internal id mismatches.
  - `CcxtExtract.Pipeline` now surfaces `orphan_entries` and `id_mismatch_entries`, validates internal ids for `describe/*.json` and `load_markets/*.json`, and flags global discovery entries whose `id` is absent from `exchanges.json`.
  - Regression tests now cover injected describe/load_markets id mismatches, orphan per-exchange files, and orphan ids in global discovery files.

- [ ] **Audit 2: Determinism and reproducibility** [D:3/B:8/U:8 → Eff:2.67] 🎯
  Verify that the same discovery inputs plus fixed `ccxt_version` and `extracted_at` produce identical pipeline output. Look for unstable ordering, timestamp leaks, or map/array nondeterminism that would make downstream diffs noisy or hide real extraction regressions.
  Success criteria:
  - [ ] Two fixed-input pipeline runs produce byte-stable output.
  - [ ] Manifest exchange ordering is stable.
  - [ ] Any intentional nondeterminism is documented; any accidental nondeterminism becomes a bug.

- [ ] **Audit 3: QuickBEAM runtime extraction correctness** [D:4/B:9/U:8 → Eff:2.13] 🎯 `[P]`
  Re-audit runtime extraction for `exchanges`, `describe`, `public_exchanges`, and `load_markets` using a representative exchange matrix. Focus on sentinel preservation, alias exclusion, referral normalization, live-vs-cached drift, and cases where CCXT runtime values are silently coerced or dropped.
  Success criteria:
  - [ ] Representative live spot-checks match cached expectations or produce a documented drift finding.
  - [ ] `__function:` and `__undefined` sentinel handling is verified on real exchanges.
  - [ ] `loadMarkets()` failures are classified as expected external failures or extraction bugs, never left ambiguous.

- [ ] **Audit 4: OXC structural extraction correctness** [D:4/B:9/U:8 → Eff:2.13] 🎯 `[P]`
  Re-audit `sign_method`, `handle_errors`, `parse_methods`, `ws_methods`, and `overrides` extraction against TypeScript source. Look for method-discovery gaps, exported-class assumptions, computed or inherited method edge cases, and REST/WS grouping mistakes that current tests may not cover.
  Success criteria:
  - [ ] A targeted exchange sample is checked directly against TS source for every structural extractor.
  - [ ] Method-name, signature, and body-presence mismatches are recorded as findings.
  - [ ] Any missed structural pattern becomes a regression test and a validator gap note.

- [x] **Audit 5: Pipeline assembly and nullability semantics** [D:3/B:9/U:9 → Eff:3.00] 🎯
  Audit `CcxtExtract.Pipeline` for places where valid `nil` and missing/corrupt data can be confused. Focus on REST/WS grouping, override merging, handle-errors renaming, markets/describe presence semantics, and the distinction between "not applicable" and "failed to extract."
  Success criteria:
  - [x] Every nullable output section has an explicit reason it can be `null`.
  - [x] Missing/corrupt source artifacts cannot silently collapse into expected nulls.
  - [x] One synthetic test exists for each audited nullability edge.

  Result:
  - No confirmed real-artifact nullability defects were found in the tracked fixture set for this scope.
  - The audit confirmed legitimate `null` cases in cached fixtures for alias exchanges, non-pro WS layers, root-exchange overrides, empty `parse_methods`, and exchanges whose source data explicitly reports `handle_errors: null`.
  - The audit exposed two pipeline blind spots: malformed global discovery entries (`methods_rest`, `handle_errors`, `parse_methods`, `ws_methods`) could collapse into output `null` without being reported, and `Schema.validate/1` was too shallow to reject partial `class_info`, `methods`, and `handle_errors` maps during pipeline assembly.
  - `CcxtExtract.Pipeline` now validates those global entry shapes and records malformed entries under `corrupt_entries`; `Schema.validate/1` now checks `class_info`, `methods`, and `handle_errors` deeply enough for pipeline assembly to flag partial structures.
  - Regression coverage now includes synthetic corrupt-entry cases plus cached fixture assertions for legitimate null reasons.

- [ ] **Audit 6: Round-trip validation blind spots** [D:3/B:8/U:9 → Eff:2.83] 🎯
  Current round-trip validation checks a reference subset. Expand the audit to a wider exchange matrix and look for bug classes that schema validation and reference-only round-trips miss. Treat every escaped bug as evidence that the validation surface is too narrow or too shallow.
  Success criteria:
  - [ ] The audit covers more than the current reference subset.
  - [ ] Each escaped bug is categorized as a schema gap, round-trip gap, coverage gap, or extraction bug.
  - [ ] The validator is strengthened only where a real escaped bug justifies it.

- [ ] **Audit 7: Coverage report consistency** [D:3/B:7/U:7 → Eff:2.33] 🚀 `[P]`
  Compare `coverage_report` claims against actual discovery artifacts and assembled pipeline output. Find false positives, false negatives, or applicability mistakes that could make the project look healthier than it is.
  Success criteria:
  - [ ] Coverage status matches actual artifact presence for the audited sample.
  - [ ] Alias, derived, and WS applicability rules are verified on real examples.
  - [ ] Any misleading coverage result is either fixed or documented as an audit limitation.

- [ ] **Audit 8: External parity and omission checks** [D:4/B:8/U:8 → Eff:2.00] 🎯 `[P]`
  Use the existing comparison scripts against old specs and the Go extractor to hunt for omissions that internal validators cannot see. The goal is not feature parity for its own sake, but to catch fields or behaviors that should already be extractable and may currently be missing or misclassified.
  Success criteria:
  - [ ] Suspected omissions are grouped into "real extraction gap", "consumer-specific", or "future parity task".
  - [ ] Any item claimed as "covered" or "richer" is spot-checked for truth, not trusted blindly.
  - [ ] Real extraction gaps are promoted into concrete bug tickets or roadmap tasks.

- [ ] **Audit 9: Regression-test follow-through** [D:2/B:9/U:9 → Eff:4.50] 🎯
  Every confirmed audit finding must end with a failing test in the right tier before the bug is considered understood. Do not rely on prose findings alone. The audit is only complete when the bug can be reproduced automatically.
  Success criteria:
  - [ ] Each confirmed bug has a matching test or fixture proving the failure.
  - [ ] Tests fail loudly on bad output and never silently pass on unexpected errors.
  - [ ] Fixes are not merged without the reproducer staying in the suite.

## Execution Order

Run the audit in this order unless a newly-found bug changes priorities:

1. Audit 1: Manifest and artifact integrity
2. Audit 5: Pipeline assembly and nullability semantics
3. Audit 6: Round-trip validation blind spots
4. Audit 2: Determinism and reproducibility
5. Audit 3: QuickBEAM runtime extraction correctness
6. Audit 4: OXC structural extraction correctness
7. Audit 7: Coverage report consistency
8. Audit 8: External parity and omission checks
9. Audit 9: Regression-test follow-through

The order is intentional: catch silent data-loss and validator blind spots first, then spend time on deeper live/runtime and parity checks.

## Finding Template

Use this format for every audit finding:

- Layer:
- Exchange or artifact:
- Reproduction command:
- Expected behavior:
- Actual behavior:
- Existing guard that should have caught it:
- Why it escaped:
- Required regression test:
- Fix owner or next task:

## Audit Findings

No confirmed real-artifact defects were found in the tracked fixture set during Audit 1. The confirmed finding was a validation/reporting blind spot in the integrity surface:

- Layer: Pipeline and validation artifact integrity
- Exchange or artifact: Synthetic fixtures (`fakex`, `rogue`) plus cached fixture baseline
- Reproduction command: `mix test test/ccxt_extract/pipeline_test.exs test/integration/cached/pipeline_cached_test.exs test/integration/cached/validation_cached_test.exs`
- Expected behavior: Missing, corrupt, orphan, and id-mismatch cases are reported separately; clean cached fixtures produce empty integrity lists
- Actual behavior: Before the fix, orphan artifacts and internal id mismatches were not surfaced in pipeline stats or validation reports
- Existing guard that should have caught it: Cached describe tests asserted `describe.id` consistency, but only in the integration layer and not in the shared pipeline/reporting path
- Why it escaped: The pipeline trusted manifest membership and filenames, and it did not scan for unreferenced artifacts or validate internal ids inside decoded files
- Required regression test: Added synthetic tests for describe/load_markets id mismatches, orphan per-exchange files, and orphan ids in global discovery files
- Fix owner or next task: Completed in Audit 1; carry the new integrity buckets forward in later audits

Audit 5 confirmed a second blind spot in pipeline assembly rather than a tracked-fixture defect:

- Layer: Pipeline assembly and fast structural validation
- Exchange or artifact: Synthetic fixtures for `methods_rest.json`, `handle_errors.json`, `parse_methods.json`, plus WS-only `class_hierarchy.json` / `methods_ws.json` cases
- Reproduction command: `mix test.json --quiet test/ccxt_extract/schema_test.exs test/ccxt_extract/pipeline_test.exs test/integration/cached/pipeline_cached_test.exs`
- Expected behavior: Corrupt global discovery entries are surfaced explicitly, and partial structure maps fail pipeline validation instead of collapsing into expected-looking `null`s
- Actual behavior: Before the fix, malformed global entries could be skipped without landing in `corrupt_entries`, and `Schema.validate/1` accepted partial `class_info`, `methods`, and `handle_errors` maps during pipeline assembly
- Existing guard that should have caught it: Full JSON Schema validation caught these shapes only in the later `mix ccxt_extract.validate` path, not in `mix ccxt_extract.pipeline`
- Why it escaped: Pipeline assembly relied on shallow map-or-null checks and did not validate the shape of global discovery entries before indexing them
- Required regression test: Added synthetic corrupt-entry tests for `methods_rest`, `handle_errors`, and `parse_methods`, plus pipeline validation tests for WS-only `class_info` and `methods`
- Fix owner or next task: Completed in Audit 5; carry the clarified nullability semantics forward in later audits and consumer docs

## Done Criteria

The audit is complete when:

- [ ] The prioritized audit tracks have been worked or explicitly deferred with reasons.
- [ ] Confirmed bugs have reproducible tests.
- [ ] The validator and coverage story reflect what the audit actually learned.
- [ ] The remaining risks are explicit enough to turn into roadmap tasks without re-discovery.
