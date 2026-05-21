---
sha: 4dce59c5584b3edf59f62ae61a87b3c16570a2c6
short_sha: 4dce59c
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: task(93): websocket.heartbeat — new v4 WS group, ping/pong keep-alive extraction (#32)

**Original commit:** 4dce59c — `task(93): websocket.heartbeat — new v4 WS group, ping/pong keep-alive extraction (#32)`
**Author:** E.FU
**Files touched:** 23
**LOC:** ±1421
**Source PR:** #32

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 8 | bug | lib/mix/tasks/ccxt_extract.ws_heartbeat.ex | Scoped run naming a variant without its WS root drops `extends`-chain ancestors → child mis-derives `keep_alive_ms` and emits a dishonest `keep_alive_resolved_from` | filed as rmap Task 146 (bug) |
| 2 | 6 | bug | lib/ccxt_extract/contract_test.ex:1081 | `websocket_heartbeat_shape_valid` honesty invariant let a `ping_kind: "none"` record pass while carrying populated heartbeat fields | applied |
| 3 | — | recorded | lib/ccxt_extract/discovery_loader.ex | `ws_heartbeat.json` gets no artifact-level validation — a malformed row bypasses `corrupt_entries` | recorded — pre-existing generic-loader pattern, not a defect of this commit (see note) |
| 4 | — | drop | priv/schema/exchange_v4.json, lib/ccxt_extract/schema.ex | "additive required `websocket` group needs a schema-version bump" (Copilot ×2 + CodeRabbit) | dropped — documented greenfield decision (PR #32 body, CHANGELOG, `provenance.ex` moduledoc all state "no schema-version bump") |
| 5 | — | drop | lib/mix/tasks/ccxt_extract.ws_heartbeat.ex:41-51 | snake_case → camelCase local variables (CodeRabbit) | dropped — false positive; snake_case is Elixir's universal convention and the entire repo (incl. this commit) is snake_case; no `.coderabbit` config exists |
| 6 | — | drop | lib/ccxt_extract/ws_heartbeat.ex | moduledoc references a non-existent test file (Copilot) | dropped — stale; already corrected in the squashed second commit ("fix moduledoc ref"); the merged commit references `ws_heartbeat_integration_test.exs`, which exists |
| 7 | — | drop | lib/mix/tasks/ccxt_extract.ws_heartbeat.ex:57 | hard-coded `priv/discoveries/ws_heartbeat.json` in the completion log (CodeRabbit) | dropped — identical pattern in every sibling extractor task (`ws_methods`, `fetch_methods`, `rate_limit_buckets`); fixing only here creates inconsistency |
| 8 | — | drop | SCHEMA.md:477 | `keep_alive_ms` example `18000` vs `180000` (CodeRabbit) | dropped — false positive; the example is bybit-shaped (`json_message` + `{op:ping}`) and 18000 is bybit's real `keepAlive`; CodeRabbit conflated it with the binance inheritance narrative |
| 9 | — | drop | test/integration/cached/ws_heartbeat_cached_test.exs:19 | `File.read!` without a friendly missing-file error (Copilot) | dropped — no friendly-error pattern exists in the 23 cached tests; raw `File.read!` in `setup_all` is the dominant convention; the 6 files using `File.exists?` use it for graceful degradation in helpers, not for `setup_all` messaging |

## Auto-applied fixes

- `lib/ccxt_extract/contract_test.ex`: extended `ws_heartbeat_honesty_findings/2` with five `ping_kind: "none"` honest-empty coherence checks (`ping_payload`, `ping_payload_kind`, `max_ping_pong_misses`, `keep_alive_resolved_from`, `has_pong_handler` must all be empty/false). A REST-only no-WS record can no longer pass the invariant while carrying populated heartbeat fields — the invariant now fully enforces its advertised honest-empty contract.
- `test/ccxt_extract/contract_test_test.exs`: added five tests, one per new coherence check.

Verification: `mix test.json test/ccxt_extract/contract_test_test.exs` — 108/108 pass (incl. the 5 new tests). `mix ccxt_extract.contract_test` — `websocket_heartbeat_shape_valid: 0` findings corpus-wide (every corpus `none` record originates from `none_record/0`, which satisfies all five new checks).

## Discuss-tier resolutions

- **Finding 1 (discuss-design — dropped + filed).** The correct fix introduces a new `WsHeartbeat` ancestor-closure helper AND expands the `scope` MapSet passed to `AggregateWriter.write!` (without the expansion, the scoped merge keeps the stale on-disk ancestor copy and appends the fresh one — duplicate entries). That is a behaviour change to scoped-extraction merge semantics. Claude+Codex converge that it is a real P8 correctness bug; they diverge on whether a post-merge audit pass should ship a semi-verified scoped-extraction-semantics change without a fresh-corpus `--exchange <variant>` integration test. Resolution per the audit-review divergence rule: dropped from auto-apply, filed as **rmap Task 146** (Phase 0, `maintenance`, `bug` marker) for a dedicated, corpus-verified implementation session.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex P8 + Codex-GH-bot P1 + Claude — 3 reasoners), 2 (Codex P6 + CodeRabbit + Claude — 3 reasoners), 3 (Codex P7 + CodeRabbit — 2 reasoners)
Codex-only findings (verified): —
Codex-only findings (discarded as over-flag): — (Codex returned exactly the 3 substantive findings, no noise)

## Bot review triage (PR #32)

CodeRabbit's PR review failed to post fully (the PR was merged before review completed). Nine bot comments were retrieved via the GitHub API — 4 Copilot, 1 Codex-GH-bot, 4 CodeRabbit inline + 1 CodeRabbit summary. Triage outcome: 2 corroborated findings handled (Finding 2 applied; Finding 1 filed as Task 146), 1 corroborated finding recorded (Finding 3), 6 dropped as verified non-defects or false positives (Findings 4-9).

**Finding 3 — recorded, not applied.** The missing artifact-level validation is a property of the *generic* `load_exchange_lookup` path, shared by every discovery file (`ws_methods.json`, `fetch_methods.json`, `rate_limit_buckets.json`, `parse_methods.json`, …). Commit 4dce59c correctly followed that established pattern; a `ws_heartbeat`-only validation branch would be inconsistent special-casing. The realistic trigger (a hand-corrupted, deterministically-generated, gitignored discovery file) is near-zero, and project guidance defers project-wide robustness refactors while the v4 contract surface is open. No code change and no task — recorded here as the durable record.

**Note on CodeRabbit configuration.** CodeRabbit's "use camelCase for Elixir variable names" guideline (Finding 5) is an org-level CodeRabbit setting that is wrong for this repository — there is no `.coderabbit` config file, and the entire codebase (including this commit) is idiomatic snake_case. It will keep producing false-positive noise on every Elixir PR until the org-level CodeRabbit setting is corrected.
