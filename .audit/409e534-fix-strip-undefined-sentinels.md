---
sha: 409e5342b64bf8bd653ef7aa0a53871d7333b2f1
short_sha: 409e534
audited_at: 2026-05-20
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: fix: strip __undefined sentinels + widen precision schema for markets.currencies (Task 97 follow-up)

**Original commit:** 409e534 — `fix: strip __undefined sentinels + widen precision schema for markets.currencies (Task 97 follow-up)`
**Author:** E.FU
**Files touched:** 6
**LOC:** +128 / −4

**Provenance:** direct commit to `development` (no PR resolved). Recorded, not flagged.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | test/support/staged_discoveries.ex:22 | VM-local tmp counter + shared `tmp_dir` → cross-VM `rm_rf!` can delete another run's active corpus | applied |
| 2 | 4 | doc-gap | lib/ccxt_extract/currencies.ex:43 | Moduledoc says `precision` is number-or-null — contradicts this commit's own schema widening | fixed in e6c9617 (mid-audit) |
| 3 | 3 | doc-gap | lib/ccxt_extract/currencies.ex:113 | `strip_undefined/1` added without `@spec` | applied (audit commit) |
| 4 | — | bug | lib/ccxt_extract/currencies.ex:111 | List of bare scalar `"__undefined"` not stripped (asymmetric recursion) | dropped — see below |

## Auto-applied fixes (audit commit)

- **test/support/staged_discoveries.ex:22** — the staged-corpus tmp path used `ccxt_staged_discoveries_#{:erlang.unique_integer([:positive])}`. `:erlang.unique_integer/1` is VM-local and its counter restarts each `mix test` run, while `System.tmp_dir!/0` is shared across concurrent VMs. This commit added `File.rm_rf!(tmp)` before `mkdir_p!` (to clear a crashed run's leftover) — which turned a latent same-path collision into a **destructive** one: two concurrent test VMs (parallel `mix test`, or separate worktree sessions sharing `/tmp`) can generate the same path, and one VM's `rm_rf!` deletes the other's active staged corpus mid-test. Namespaced the path with `System.pid()` (unique per VM); `rm_rf!` retained as now-harmless defensive cleanup. Comment rewritten to state the cross-VM rationale.
- **lib/ccxt_extract/currencies.ex:113** — added `@spec strip_undefined(term()) :: term()` (project spec convention; `.credo.exs` has `Readability.Specs` disabled so it was not gate-caught).

## Mid-audit note — e6c9617

While this audit was running, commit `e6c9617` ("chore: narrow derivation scope to the 7-exchange option-seller set") landed on `development` from a parallel surface and swept up part of this audit's uncommitted working-tree edits. Finding #2 (the `currencies.ex` moduledoc `## Stripping` paragraph — which this commit had left saying `precision` is "number-or-null … would fail validation" while the same commit widened `precision` to `number|string|null`; rewritten to the durable truth: the sentinel is a serialization artifact, not real data, and the typed schema has no slot for it) was committed in `e6c9617`, not in this `audit(...)` commit. The fix is correct and in place — attribution recorded here for `git revert` clarity. `e6c9617` itself is unaudited and is flagged for the next audit-review run.

## Discuss-tier resolutions

- (none)

## Findings considered & dropped

- **Codex #4 — asymmetric list recursion in `strip_undefined/1` (rated `discuss`; Claude-corroborated).** `strip_undefined` rejects `"__undefined"`-valued *keys* in maps but, for a list, only maps `strip_undefined` over elements — a bare `"__undefined"` scalar element in a list survives. **Dropped:** no triggering corpus input exists — no CCXT currency or network field is a list of bare scalars (`networks`/`limits` are maps; `tiers`, when present, is a list of maps, which the recursion handles and the commit's test covers). Codex itself rated it `discuss`, not a confident bug, and flagged "is that a real corpus case?" as the open question. "Completing" the recursion would also introduce a genuine semantic question (drop a JS-`undefined` array element, shifting indices, vs keep as null) with no right answer absent a real case. The helper is correct for the actual data shape. Below the ceremony floor (2-LOC nit, no real input) → no rmap follow-up; revisit only if a future currency field is a scalar list.

## Audit notes

`strip_undefined/1` (recursive sentinel drop) and the `precision` schema widening to `number|string|null` are both correct and well-tested — five new `currencies_test.exs` cases cover currency-level, network-level, list-of-maps, and nested-non-typed-map (`limits`) stripping. The `staged_discoveries.ex` flaky-test fix (`File.rm_rf!` before `mkdir_p!`) addressed the right symptom; finding #1 above completes it for the concurrent-VM case. CHANGELOG and SCHEMA.md updated; no ROADMAP flip needed (Task 97 was already done — this is a follow-up).

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 4 (list-recursion asymmetry — also noted by Claude; dropped, no corpus trigger)
Codex-only findings (verified & applied): 1 (cross-VM tmp collision), 2 (moduledoc precision contradiction), 3 (`strip_undefined` `@spec`)
Codex-only findings (discarded as over-flag): —
Codex verification note: read the touched files, checked QuickBEAM `_prepare`, searched `priv/discoveries`/`priv/output` for `__undefined`, ran `currencies_test.exs` 13/13 green.
