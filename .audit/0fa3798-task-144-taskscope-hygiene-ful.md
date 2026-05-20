---
sha: 0fa37983e8da060d6f47d30f91d9944c0f685b4b
short_sha: 0fa3798
audited_at: 2026-05-20
auditor_model: claude-opus-4-7
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: task(144): TaskScope hygiene — full OXC discovery surface migrated to parse_and_resolve

**Original commit:** 0fa3798 — `task(144): TaskScope hygiene — full OXC discovery surface migrated to parse_and_resolve`
**Author:** E.FU
**Files touched:** 12
**LOC:** +33 / −129

**Provenance:** direct commit to `development` (no PR; `gh search prs --merge-commit` resolved none). The recent ccxt_extract workflow is direct task commits to `development` across surfaces — recorded, not flagged as a defect.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 2 | doc-gap | roadmap/tasks.toml (Task 144 `implemented`) | `implemented` names only the 3 AC tasks; commit migrated 7 | dropped — see below |

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- (none)

## Findings considered & dropped

- **Codex #1 — `implemented` text scope (pri 2, Cat 6).** Codex noted Task 144's `implemented` field records only `handle_errors`/`parse_methods`/`sign_methods` while the commit migrated 7 mix tasks. **Dropped:** the `implemented` field correctly scopes to Task 144's `acceptance_criteria` ("3 mix tasks migrated"). The remaining 4 tasks (`classes`, `fetch_methods`, `methods`, `ws_methods`) were an explicit opportunistic follow-up and are documented as such in the CHANGELOG entry. Two fields, two scopes — not drift. Genuinely better-as-is; a "fix" would just duplicate CHANGELOG prose into roadmap metadata.

## Audit notes

Pure deduplication refactor: 7 OXC-discovery mix tasks drop their duplicated `OptionParser` + validation + `load_universe` + `resolve_scope!` + `to_manifest_value` preamble in favor of the single `TaskScope.parse_and_resolve!/1,3` helper. Local `@switches` and `alias Scope` removed. `methods.ex` keeps its `--type` switch via the helper's extra-switches arg; `classes.ex` intentionally discards the narrowed scope (documented exception). Error-message wording shifts to the standardized helper versions — tests use loose regexes, no breakage. CHANGELOG, moduledoc, and ROADMAP (Task 144 → ✅ via rmap) all updated in lockstep. No behavior change beyond error-string wording.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified): 1 (doc-scope, dropped on verification as defensible-as-is)
Codex-only findings (discarded as over-flag): —
Codex verification note: `oxc_scope_flags_test` 45/45 green; compile/credo/dialyzer were sandbox-blocked on Codex's side (`Mix.PubSub` TCP `:eperm`) — re-run clean in this audit's harness pass.
