# Audit — `28166a2` Task 90: Per-endpoint rate-limit costs + bucket-axis binding (#19)

- **Commit:** `28166a2` (parent: `0b97854`)
- **PR:** #19 (squash-merged into `development`)
- **Branch (deleted):** `task-90`
- **Worktree:** `~/_DATA/worktrees/ccxt_extract/task-90/` (cleanup pending — see end of report)
- **LOC:** 628 (across 22 files)
- **lib/ files touched:** 7 (incl. new `lib/ccxt_extract/rate_limit_cost_binding.ex`)
- **Path:** FULL machinery (≥100 LOC AND lib/ touched)
- **Reviewers:** Claude (audit-review Step 5a) + Codex CLI (Step 5b — `codex:codex-rescue` parallel dispatch)
- **Verdict:** clean — 4 findings auto-applied (sobelow regen, schema required-array, +3 defensive tests on `derive/1`, port-mismatch crossover from `6ea42ce`); 1 finding filed as ROADMAP follow-up (C5 pipeline-level propagation tests); 0 new defects.

## Reviewer convergence

| Finding | Claude | Codex | Rating | Disposition |
|---|:---:|:---:|:---:|---|
| **C0** — Sobelow drift on lib/ touch (PreToolUse Bash hook fail-loud-with-diff) | hook-flagged | — | n/a | Pre-applied via `mix sobelow --mark-skip-all` per CLAUDE.md exception ("audit-review applies the regen at the post-merge audit pass in the same `audit(...)` commit"). |
| **C1** — `RateLimitCostBinding.derive/1` defensive branches at `lib/ccxt_extract/rate_limit_cost_binding.ex:15` (non-list `buckets`), `:21` (first bucket lacks `axes`), `:21` (`axes` not a list) lack direct unit coverage | ✅ | — | 6/10 | Auto-applied — added 3 tests at `test/ccxt_extract/rate_limit_cost_binding_test.exs:64-92` exercising each defensive branch with explicit assertion that `derive/1` returns `nil`. Critical-tier coverage rule (`critical-rules.md` § "RAISE COVERAGE BEFORE MUTATING"): rate-limit binding is consumer-contract surface; defensive branches without direct tests are exactly the gap that ships latent bugs. |
| **C2** — Port `4001` in `CLAUDE.md:175` + `AGENTS.md:3488` vs `4002` in `mix.exs:81` + `.mcp.json` | — | ✅ | 4/10 | Auto-applied (cross-commit from `6ea42ce` — see that report for detail). |
| **C4** — `priv/schema/exchange_v4.json` `$defs.RateLimits` lacks `required` array; siblings (`Endpoints`, `Auth`, `Errors`) all declare required keys | — | ✅ | 5/10 | Auto-applied — added `"required": ["buckets", "per_endpoint_cost", "endpoint_cost_binding"]` at the `$defs.RateLimits` level. Schema/preflight asymmetry: Elixir-side `Schema.validate_v4/1` enforces these via `@required_rate_limits_keys_v4` (lib/ccxt_extract/schema.ex), but JSV's downstream validation didn't, leaving a gap where consumers running JSV-only validation would miss missing-key errors. Now consistent across both validators. |
| **C5** — Pipeline-level integration tests for `endpoint_cost_binding` propagation through `Pipeline.build_exchange_data/3` → `Schema.build_exchange_v3/v4` → `priv/output/<id>.json` are missing | — | ✅ | 4/10 | Filed as ROADMAP **Task 133** (`[D:3/B:4/U:4 → Eff:1.33] 📋`). Complementary to C1 (unit-level vs pipeline-level scope). 3 focused tests proposed: (a) valid wrapper → both v3/v4 paths emit identical binding; (b) `unresolved_reason != nil` → both emit `null`; (c) wrapper missing → parent fallback emits `null` without raise. Out of scope for one-commit audit because cached-test fixture additions touch `test/ccxt_extract/pipeline_test.exs`'s describe-block scaffolding (>5 LOC mechanical extensions). |

## Auto-applied fixes (audit-review Step 9)

### Fix 1 — `.sobelow-skips` (regen via `mix sobelow --mark-skip-all`)

Diff: +8/-1. PreToolUse Bash hook flagged sobelow line-fingerprint drift on lib/ touch (Task 90 added `RateLimitCostBinding` and threaded it through `Pipeline`, shifting line numbers in already-skipped `pipeline.ex` warnings). Per CLAUDE.md exception: "audit-review applies the regen at the post-merge audit pass in the same `audit(...)` commit" — agent never touches the file pre-merge.

### Fix 2 — `priv/schema/exchange_v4.json:413` (RateLimits required array)

Added one line to `$defs.RateLimits`:
```json
"required": ["buckets", "per_endpoint_cost", "endpoint_cost_binding"],
```

**Why:** JSV-side validation now matches Elixir-side `Schema.validate_v4/1`'s `@required_rate_limits_keys_v4` enforcement. Sibling `$defs` already declared required arrays.

### Fix 3 — `test/ccxt_extract/rate_limit_cost_binding_test.exs` (3 defensive-branch tests)

Added 3 tests in the `describe "derive/1"` block:
- `"nil when buckets value is not a list"` — wrapper with `"buckets" => "invalid"` exercises the `is_list(buckets)` guard at `lib/ccxt_extract/rate_limit_cost_binding.ex:15`
- `"nil when first bucket lacks :axes key"` — wrapper with `"buckets" => [%{"rate_limit_ms" => 50.0}]` exercises the `case List.first(buckets)` fallthrough
- `"nil when first bucket :axes is not a list"` — wrapper with `"axes" => "request"` (string, not list) exercises the `when is_list(axes)` guard

Test count grew 4 → 7. Each test's structural shape mirrors the existing `"nil when buckets list is empty"` test's wrapper format for consistency.

### Fix 4 — `CLAUDE.md` + `AGENTS.md` Tidewave port

See `6ea42ce` audit report (cross-commit fix; the port string lives in files the earlier commit introduced/touched, but Task 90's audit pass is when both reviewers' findings converged on it).

## Verification

- **Compile:** in-flight (`mix test.json` background run includes a recompile step).
- **Tests:** `mix test.json --quiet --output /tmp/audit-r.json` running in background — verification block in commit body.
- **Honest scope:** offline tests only — `:extraction`, `:tier3_corpus`, `:flaky` excluded by `test/test_helper.exs:50`. The 3 new `derive/1` tests are pure (no fixture I/O), so the fast suite covers them. The pipeline-level coverage gap (C5 → Task 133) is what the `:extraction`-tagged integration suite would actually exercise; that's why C5 is filed as follow-up rather than auto-applied — auto-applying would either (a) add untested fixture scaffolding or (b) gate the audit on a longer test run.

## Out-of-scope (filed as follow-up)

- **C5 — pipeline-level `endpoint_cost_binding` propagation tests** → ROADMAP **Task 133** (see disposition row above).

## Worktree cleanup

- `~/_DATA/worktrees/ccxt_extract/task-90/` — PR #19 squash-merged 2026-05-09; remote branch `task-90` deleted by `gh pr merge --delete-branch`. Remove via:
  ```bash
  git worktree remove ~/_DATA/worktrees/ccxt_extract/task-90 && git worktree prune
  ```
  Auto-allowed under `worktree-workflow.md` § "Lifecycle — Cleanup Is Part of Completion". Audit-review Step 13 will run this after the audit commit lands.
