---
sha: f3ea824b1043cdbc056e46b82b8a5ee106c7b295
short_sha: f3ea824
audited_at: 2026-05-14
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Task 114: extraction determinism audit (#28)

**Original commit:** f3ea824 — `Task 114: extraction determinism audit (#28)`
**Author:** E.FU
**Files touched:** 32
**LOC:** +1690 / -255

PR #28 squash-merge. Adds the extraction-determinism gate: `mix ccxt_extract.determinism_check`, `CcxtExtract.JsonDiff`, `AstNormalize.to_encodable/1` deep key-sort, `Pipeline.check_version_drift!/1` + `bundle_sha256/1`, `Scope.merge_manifest_values/2`.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug / doc-gap | test/ccxt_extract/aggregate_writer_test.exs:446 | Dead test passes the removed `normalize: false` opt; name claims a "no conversion" contract this commit explicitly deleted ("no opt-out"), and it never asserted that contract — only `count == 1` | applied — deleted the vacuous test |
| 2 | 6 | bug | lib/mix/tasks/ccxt_extract.determinism_check.ex | `@default_diff_dirs` omits `fixtures/signing`; a `--task ccxt_extract.signing_fixtures` run collects 0 files → vacuous "0/0 equal → OK" pass | applied — added `fixtures/signing` to defaults + `report.total == 0` is now a loud failure |
| 3 | 6 | bug | lib/mix/tasks/ccxt_extract.setup.ex:134 | `copy_bundle_to_priv` skips the copy on same byte-*size*; a same-size CCXT bump leaves a stale bundle that `record_versions/1` then hashes as the drift baseline | applied — compare by `Pipeline.bundle_sha256/1`, not size |
| 4 | 5 | extraction | lib/ccxt_extract/ast_normalize.ex:70 | `to_encodable/1` composed `normalize/1` (deep walk) inside `wrap_sorted`'s recursion → a value at depth D was `normalize`'d D times; O(depth) redundant re-normalization on every write path | applied — added non-recursing `encodable_entry/1` (current-level `:type` rewrite only; `wrap_sorted` already recurses) |
| 5 | 6 | bug / doc-gap | priv/ccxt_version.json | Tracked baseline version file lacks `bundle_sha256`, so `check_bundle_drift!` takes `is_nil(recorded) -> :ok` — the bundle-drift half of the Task 114 guard is inert in the shipped repo until the first local `mix ccxt_extract.setup` | applied — back-filled `bundle_sha256` (verified `priv/ccxt` HEAD == recorded `source_git_sha`, so the local bundle's hash IS the correct baseline) |
| 6 | 4 | todo-marker | lib/mix/tasks/ccxt_extract.determinism_check.ex:10 | Strip-keys workaround for deferred Task 137 documented as "(deferred Task 137)" without a `TODO:` prefix — invisible to `mix credo` tag tracking | applied — added `# TODO(Task 137):` comment at `parse_strip_keys/1` |
| 7 | 3 | bug | lib/ccxt_extract/json_diff.ex (context/2) | `--context-bytes N` advertised as preview width but `JsonDiff.context/2` hardcoded an 80-byte window; values > 80 silently ignored | applied — threaded `:context_bytes` through `diff_files/3`/`diff_terms/3` → `byte_diff_context/3` → `context/3` (default `@default_context_bytes 80`) |
| 8 | 3 | doc-gap | CLAUDE.md "Common commands" | `mix ccxt_extract.determinism_check` not added to the Common-commands block (the commit added a "Determinism gate" prose section but not the command reference) | applied — added to the Common commands block |
| 9 | — | discuss-design | lib/ccxt_extract/discovery_writer.ex (+14 sites) | Commit spread `File.write!(Jason.encode!(to_encodable(x), pretty: true))` across 15 executable `lib/` write sites; `JsonIO` already owns the read side — candidate `JsonIO.write_json!/2,3` + a `deterministic_write` contract invariant | dialogue-resolved (convergent) → filed ROADMAP Task 138 |
| 10 | 2 | abstraction | lib/ccxt_extract/json_diff.ex (canonical_encode/sort_keys) | `JsonDiff.canonical_encode`/`sort_keys` duplicates `AstNormalize.to_encodable`/`wrap_sorted` (~10 LOC, two recursive key-sorters) | list-only — cosmetic, both unit-tested, and the layers differ (emit boundary vs decoded-JSON comparison); not worth coupling generic `JsonDiff` to OXC-aware `AstNormalize` |

## Auto-applied fixes

- `test/ccxt_extract/aggregate_writer_test.exs`: deleted the dead `normalize: false` test (the option was removed from `AggregateWriter` by this commit).
- `lib/mix/tasks/ccxt_extract.determinism_check.ex`: `@default_diff_dirs` now includes `fixtures/signing`; `execute_check/3` raises on `report.total == 0` (a run that compared nothing is a misconfiguration, not a pass); `:context_bytes` threaded into the `diff_all` opts; `# TODO(Task 137):` marker added at `parse_strip_keys/1`; moduledoc `--diff-dirs` default + exit-code table updated.
- `lib/mix/tasks/ccxt_extract.setup.ex`: `copy_bundle_to_priv/0` compares bundles by `Pipeline.bundle_sha256/1` instead of byte size, so a same-size CCXT bump can no longer leave a stale bundle for `record_versions/1` to hash as the baseline.
- `lib/ccxt_extract/ast_normalize.ex`: `to_encodable/1` now uses non-recursing `encodable_entry/1` (the `:type` rewrite for the current level only) — `wrap_sorted/1` already recurses via `to_encodable/1`, so the prior `normalize_entry/1` re-walked every descendant once per ancestor level. Behavior-preserving (normalize is idempotent); single-pass instead of O(depth). `@doc` updated.
- `lib/ccxt_extract/json_diff.ex`: added `@default_context_bytes 80`; `diff_files/3` and `diff_terms/3` read `opts[:context_bytes]`; `byte_diff_context/3` + `context/3` take the width; `@doc`/comments de-hardcoded from "80-char".
- `priv/ccxt_version.json`: back-filled `bundle_sha256` so the bundle-drift guard is live in the shipped baseline.
- `CLAUDE.md`: added `mix ccxt_extract.determinism_check` to the Common commands block.
- `.sobelow-skips`: regenerated via `mix sobelow --mark-skip-all` for the `json_diff.ex` line-number drift (133 → 140); pruned the stale `:133` fingerprint + the spurious blank line `--mark-skip-all` appended.
- `ROADMAP.md`: filed Task 138 under "Audit-Surfaced Follow-Ups" (finding #9).

## Discuss-tier resolutions

- **Finding #9 (dialogue-resolved, convergent):** Claude and Codex were dispatched independently on the `discuss-design` question. **Both resolved to "file as ROADMAP follow-up."** Claude's reasoning: the abstraction is sound (15 sites duplicate the deterministic-emit contract; `JsonIO` already owns reads), but adding `JsonIO.write_json!` plus a `deterministic_write` Reach invariant is ~15-file ripple + corpus-invariant design surface — per the task-prioritization ceremony floor, cross-session coordination cost earns a tracked task, not a post-merge audit-commit splat. Codex's reasoning (verbatim gist): "good abstraction because 15 executable deterministic-write sites duplicate the same normalization/encode/write contract while `JsonIO` already owns the read side, but adding `write_json!` plus a Reach invariant would touch many emit modules and expand the contract-test surface — matches the documented pattern of corpus-level invariants rather than a small audit cleanup. Track it as follow-up, not drop and not patch opportunistically here." Convergent resolution applied → `ROADMAP.md` Task 138.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (dead test), 6 (missing TODO marker)
Codex-only findings (verified + applied): 2 (diff-dirs vacuous pass), 3 (same-size bundle skip), 5 (missing `bundle_sha256` baseline), 7 (`--context-bytes` cap)
Codex-only findings (down-scoped): C8 — Codex flagged README.md omitting `determinism_check` / `--allow-version-drift` (pri 2). `determinism_check` is maintainer tooling, not consumer setup-surface — applied to CLAUDE.md "Common commands" instead (finding #8); README left unchanged.
Claude-only findings: 4 (`to_encodable` redundant deep-walk), 10 (canonical-encode duplication — list-only)

**Note on Codex tool access:** Codex's `mix compile` / `credo` / `dialyzer` / `test` runs all failed inside its sandbox with `Mix.PubSub` TCP `:eperm` (no socket access), so its findings are code-reading only. Every Codex finding was verified against actual file content before applying, and the harness was re-run locally by the auditor (see below).

## Verification (auditor-run)

- `mix compile --warnings-as-errors` — clean.
- `mix sobelow` — SCAN COMPLETE, 0 unskipped.
- `mix test.json` (offline) — 2658 passed, 0 failed, 468 excluded (`:extraction` / `:tier3_corpus` / `:flaky`).
- `mix test.json --include extraction test/integration/determinism_test.exs` — 1 passed, 0 failed; exercises the modified `JsonDiff.diff_files/3` (with the threaded `:context_bytes`) end-to-end against the real corpus.
