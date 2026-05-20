---
sha: 0a4315b688b6010e3d191b5eeeef395be6560561
short_sha: 0a4315b
audited_at: 2026-05-20
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: task(97): markets.currencies + networks — runtime ex.currencies capture + compact

**Original commit:** 0a4315b — `task(97): markets.currencies + networks — runtime ex.currencies capture + compact`
**Author:** E.FU
**Files touched:** 19
**LOC:** +734 / −115

**Provenance:** direct commit to `development` (no PR resolved). Recorded, not flagged.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | bug | lib/ccxt_extract/schema.ex:59 | `@required_markets_keys` omits `currencies` — Elixir validator drifted from JSON Schema | fixed in e6c9617 (mid-audit) |
| 2 | 6 | doc-gap | CONSUMER_CONTRACT.md:134-135 | Two checklist rows tagged "Task 97" still ⬜ after Task 97 done | applied (audit commit) |
| 3 | 3 | doc-gap | lib/ccxt_extract/currencies.ex:81-100 | 3 private helpers lack `@spec` (repo convention; sibling files comply) | applied — 2 in audit commit, `normalize_currency/1` in e6c9617 |
| 4 | 8 | bug | priv/schema/exchange_v4.json:809 | `Currency.precision` rejected hyperliquid string precision | fixed in 409e534 (in-range) |
| 5 | — | bug | lib/ccxt_extract/currencies.ex | `derive/1` leaked `"__undefined"` sentinels into typed schema | fixed in 409e534 (in-range) |
| 6 | — | doc-gap | test/support/exchange_fixtures.ex | `schema_conformant` fixture missing new required `currencies` key | fixed in cd79025 (in-range) |
| 7 | 4 | abstraction | lib/ccxt_extract/discovery_loader.ex:214 | Loader-shape map duplicated across 3 modules | dropped — see below |

## Auto-applied fixes (audit commit)

- **CONSUMER_CONTRACT.md:134-135** — flipped the two Task-97 checklist rows off the stale ⬜. "Network info" → ✅ with concrete source `markets.currencies[<code>].networks`. "Currency aliases (`commonCurrencies`)" → 🚧 — the runtime `markets.currencies` map carries native `id` per unified `code` and `raw.describe.commonCurrencies` carries the rename table, but no dedicated derived alias map shipped; 🚧 is the honest "partial" state (not ✅ — avoids claiming a deliverable not evident in the diff; not ⬜ — Task 97 is done).
- **lib/ccxt_extract/currencies.ex** — added `@spec` to `normalize_networks/1` and `normalize_network/1`. (`normalize_currency/1`'s `@spec` landed in `e6c9617` — see Mid-audit note below.) The public `derive/1` already had a spec; the sibling normalizer `ticker.ex` specs its privates. Per the project's `development-philosophy.md` spec mandate; `.credo.exs` has `Readability.Specs` disabled, so this was not gate-caught.

## Mid-audit note — e6c9617

While this audit was running, commit `e6c9617` ("chore: narrow derivation scope to the 7-exchange option-seller set") landed on `development` from a parallel surface and **swept up part of this audit's uncommitted working-tree edits**. Finding #1 (`schema.ex:59` — `@required_markets_keys` += `currencies`, re-syncing the Elixir-side validator at `schema.ex:202` with the JSON Schema's required list) and one of finding #3's three `@spec` additions (`normalize_currency/1`) were committed in `e6c9617`, not in this `audit(...)` commit. The fixes are correct and in place — attribution recorded here so a `git revert` of either commit is unambiguous. `e6c9617` itself is unaudited and is flagged for the next audit-review run.

## Discuss-tier resolutions

- (none)

## Findings considered & dropped

- **Codex #7 — loader-shape duplication (pri 4, Cat 4 abstraction; Claude-corroborated).** The `%{"market_count" => _, "markets" => _, "currencies" => _}` map is now built in `DiscoveryLoader`, `Validation`, and `LoadMarkets`. **Dropped:** a 3-key map literal is below the extraction-worth threshold — premature abstraction here (a shared constructor or struct) costs about what the duplication costs, and the three sites have genuinely different surrounding contexts (file-read vs QuickBEAM-result). `validation.ex` already carries an inline comment documenting the coupling. Per the ceremony floor (≤5-LOC abstraction nit → never track), no rmap follow-up.

## In-range self-correction

This commit shipped two latent gaps, both fixed by later commits in the same audited range — recorded here for the corpus narrative, not re-applied:
- `Currency.precision` / `NetworkInfo.precision` typed `number|null` while hyperliquid emits decimal-string precision → widened to `number|string|null` in **409e534**.
- `derive/1` did not strip QuickBEAM's `"__undefined"` sentinel → `strip_undefined/1` added in **409e534**.
- New required `currencies` key not added to the `schema_conformant` test fixture → fixed in **cd79025**.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 7 (loader-shape duplication — also raised by Claude)
Codex-only findings (verified & applied): 1 (`@required_markets_keys`), 3 (private `@spec`s)
Codex-only findings (verified, already fixed in-range): 4 (precision string type)
Codex-only findings (discarded as over-flag): —
