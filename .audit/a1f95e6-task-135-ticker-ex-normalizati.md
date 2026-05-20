---
sha: a1f95e6e211feae531dcb41ddae53815a3613008
short_sha: a1f95e6
audited_at: 2026-05-20
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: task(135): ticker.ex normalization-vocab alignment

**Original commit:** a1f95e6 — `task(135): ticker.ex normalization-vocab alignment`
**Author:** E.FU
**Files touched:** 8
**LOC:** +171 / −43

**Provenance:** direct commit to `development` (no PR resolved). Recorded, not flagged.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | doc-gap | SCHEMA.md:247 | Honesty contract says "two are prefix-bearing"; only one of four reasons is | applied |

## Auto-applied fixes

- **SCHEMA.md:247** — the ticker `_unresolved_reason` honesty contract said `(two are prefix-bearing with open suffixes: non_safe_ticker_return:* and the others are exact)` — internally contradictory: it claims "two" but names one and says the rest are exact. Of the four vocabulary strings only `non_safe_ticker_return:<callee>` carries an open suffix; `no_return_statement`, `identifier_return`, `unrecognized_return_shape` are exact. Corrected to "one is prefix-bearing … the other three are exact".

## Discuss-tier resolutions

- (none)

## Audit notes

Clean refactor: `find_safe_ticker_object` split into a find step (last `ReturnStatement` + `unwrap_ts_as`) and an exhaustive `classify_return_argument/1`, bringing `ticker.ex` to parity with `market.ex` / `balance.ex` / `trade.ex` / `transaction.ex`. New `unwrap_ts_as/1` handles `TSAsExpression` casts; the four-value `_unresolved_reason` vocabulary replaces the old wildcard misnomer. Three new unit tests (bare Identifier, unrecognized shape, TSAsExpression-wrapped return); moduledoc, SCHEMA.md, CHANGELOG, ROADMAP (Task 135 → ✅ via rmap) updated. The classify clauses are ordered specific-before-general and exhaustive (catch-all → `unrecognized_return_shape`).

**Bare-`return;` robustness — checked, not a finding.** The `case last_return do nil -> ...; %{"argument" => arg} -> ... end` would `CaseClauseError` only if a `ReturnStatement` node lacked the `"argument"` key entirely. Codex verified against the corpus that OXC's JSON-serialized AST always includes `argument` (nil for bare `return;`) — `0/1655` ReturnStatements omit it — and `unwrap_ts_as(nil)` → `classify_return_argument(nil)` → `unrecognized_return_shape`. No crash path.

The commit also appends three `load_markets.ex` entries to `.sobelow-skips` — a sobelow-skip refresh picking up Task 97's new `File.write!`/`File.mkdir_p!` sites (those skips arguably belonged in 0a4315b). Commit-hygiene nit only; nothing to apply.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified & applied): 1 (SCHEMA.md "two prefix-bearing")
Codex-only findings (discarded as over-flag): —
Codex verification note: ticker tests 26/26 green; `rmap validate --check-render` green; bare-`return;` serialization confirmed against the corpus. compile/credo were sandbox-blocked on Codex's side — re-run clean in this audit's harness pass.
