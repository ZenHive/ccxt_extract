# Audit: b860b44 — Task 83b response envelopes derivation (#27)

**Range:** `b860b44^..b860b44`
**Audited:** 2026-05-14
**Reviewers:** Claude (primary) + Codex (second opinion via `codex:codex-rescue`, foreground). Codex returned five corrosion-grade findings on `response_envelopes.ex`; all five were independently verified against the live CCXT corpus before applying. Dual-reviewer guarantee met.
**Path:** full (385-LOC `response_envelopes.ex` plus integration in `normalization.ex` / `pipeline.ex` / `schema.ex` / `discovery_loader.ex`)

## Verdict: ✅ clean — 5 fixes applied

All five findings are **correctness gaps**, not nitpicks: each one silently dropped real corpus data on the floor. The derivation *ran* and *looked* successful — the failure mode was emitting `null` slots or wrong defaults for exchanges whose shape the matcher didn't recognize. That is exactly the "looks derived, isn't" honesty-contract violation the `_unresolved_reason` vocabulary exists to prevent.

---

## Findings

### F1 (rating 10) — plural parser names dropped from N:1 fetcher routing

**File:** `lib/ccxt_extract/normalization/response_envelopes.ex` — `@parser_type_to_parse_fns`

The `@parser_type_to_parse_fns` map is the routing table that connects a parser-type slot (`"ticker"`, `"ohlcv"`, …) to the `parse*` function names that feed it. Three entries listed only the **singular** form:

- `"ticker" => ~w(parseTicker)` — missing `parseTickers`
- `"ohlcv" => ~w(parseOHLCV)` — missing `parseOHLCVs`
- `"deposit_address" => ~w(parseDepositAddress)` — missing `parseDepositAddresses`

CCXT's plural parsers are real, widely-used functions — `fetchTickers` dispatches through `parseTickers`, not `parseTicker`. With the plural name absent from the routing table, `fetchers_for_type/2` could never match those callsites, so the entire `"ticker"` / `"ohlcv"` / `"deposit_address"` slot resolved to `null` for any exchange that only implements the plural fetcher. Corpus probe: binance and okx alone carry 55+ `parseTickers` callsites — the binance ticker envelope was load-bearing-and-broken.

This is a **mechanical one-line-per-entry fix** (rating 10): the singular entries already prove the pattern; the plurals just join their counterparts.

**Fix applied:** `"ticker" => ~w(parseTicker parseTickers)`, `"ohlcv" => ~w(parseOHLCV parseOHLCVs)`, `"deposit_address" => ~w(parseDepositAddress parseDepositAddresses)`. A code comment records the corpus evidence so a future reader doesn't "tidy" the plurals back out. (`"trade"`, `"order"`, `"position"`, `"market"`, `"transaction"` already carried both forms — they were correct.)

---

### F2 (rating 8) — inline `this.safe*(response, …)` as a parser arg silently unresolved

**File:** `response_envelopes.ex` — `find_return_first_arg/1` → new `classify_return_first_arg/1`

`find_return_first_arg/1` walked the fetcher body for `return this.parseX(arg0, …)` and extracted `arg0` — but it only handled `arg0` being a *bare identifier* (a variable name it could then look up among the collected `response` bindings). When `arg0` was an **inline** `this.safeList(response, "result", [])` call — i.e. the unwrap happens *in the return expression itself*, with no intermediate `const` — `extract_identifier_name/1` returned `nil` and the whole fetcher fell through to unresolved. Whitebit, kraken, and bitget all use this inline shape.

**Fix applied:** the `@spec` for `find_return_first_arg/1` widened to `nil | String.t() | {:inline_binding, map()}`. The bare-identifier callsite now routes through `classify_return_first_arg/1`, which tries `extract_identifier_name/1` first (unchanged path) and falls to `classify_non_identifier_return_arg/1`. That helper calls the existing `extract_response_safe_call/1` — so an inline `this.safe*(response, …)` produces a fully-formed `{key, fallback_keys, default}` binding, tagged `{:inline_binding, binding}`. `derive_from_body/1` gained an `{:inline_binding, binding} -> binding` case. The existing var-binding lookup path is untouched — the new tuple threads around it.

---

### F3 (rating 8) — `response['k']` / `response.k` member access as a parser arg silently unresolved

**File:** `response_envelopes.ex` — `classify_non_identifier_return_arg/1` → new `extract_response_member_key/1`

Same `find_return_first_arg/1` blind spot as F2, different shape: when a fetcher returns `this.parseTrades(response['payload'], …)` or `this.parseTrades(response.payload, …)` — a **one-level member access on `response`** passed straight into the parser — `arg0` is a `MemberExpression`, not an `Identifier` and not a `CallExpression`. It fell through to unresolved. Corpus probe: bitso, coinex, coinmate, bittrade, and zaif all use this direct-member-access return shape.

The property name *is* the envelope key — `response['payload']` means "unwrap `response` at key `payload`." Resolving it is not interpretation; it's reading the AST.

**Fix applied:** `classify_non_identifier_return_arg/1` (added for F2) gained a second branch calling new `extract_response_member_key/1`, which matches `MemberExpression` whose `object` is `Identifier("response")` and pulls the property via new `extract_property_name/1` (handles both `Identifier` property — `response.k` — and `Literal` string property — `response['k']`). The result is wrapped as `{:inline_binding, %{"key" => key, "fallback_keys" => [], "default" => nil}}` — the same tuple F2 introduced, so it rides the same `derive_from_body/1` path. The moduledoc's `nested_response_unwrap` entry was clarified: *binding-site* nested access stays unresolved, but a *direct member-access return* DOES resolve the property as the key (F3) — these are deliberately different, and the moduledoc now says so.

---

### F4 (rating 9) — `safeValue2` / `safeList2` arity bug recorded the fallback key as the default

**File:** `response_envelopes.ex` — `extract_key_binding/2` → new `parse_remaining_args/2`

`extract_key_binding/1` parsed `rest_args` (everything after the first key) with a one-size-fits-all rule: *"all args except the last are fallback keys, the last is the default."* That rule is correct for `safeValue`/`safeList` but **wrong for `safeValue2`/`safeList2`**, whose CCXT signature is `safeValue2(obj, key1, key2, default?)`. When a `safeValue2` call supplied **no default** (3 args total: `obj, key1, key2`), `rest_args` was `[key2_node]` — and the old "last arg is the default" rule recorded `key2` as the *default value* and left `fallback_keys` empty. The envelope's fallback key was lost; a string key was emitted as a default payload. Corpus probe: zonda is the canonical victim.

**Fix applied:** `extract_key_binding/1` → `extract_key_binding/2`, now threading the `method` name through (`build_binding/3` passes it). The Literal-key clause calls new `parse_remaining_args/2`, which is method-aware:

- `method in ~w(safeValue2 safeList2)` — `[k2]` → `{[k2 as fallback], nil}`; `[k2, default | _]` → `{[k2], default}`
- default clause (`safeValue` / `safeList`) — `[default | _]` → `{[], default}`; `[]` → `{[], nil}`

`safeValueN`/`safeListN` callers hit the `ArrayExpression` clause earlier and never reach this function — documented in the helper's comment. The obsolete `collect_fallback_keys/1` was removed; new `literal_string_list/1` extracts the string-literal nodes. The `_ = method` discard in the `nested_response_unwrap` branch is gone — `method` is now genuinely used.

---

### F5 (rating 8) — top-level `_unresolved_reason: nil` falsely signalled "derived cleanly" when no fetcher dispatched

**File:** `response_envelopes.ex` — `build_result/2`

`build_result/2` unconditionally set the top-level `_unresolved_reason` to `nil`. But an exchange's `parse_dispatch` can have entries where **none of them are fetcher names** — only mutators (`createOrder`, `cancelOrder`, `transfer`) or `describe`. In that case every parser-type slot correctly resolves to `null` (there's no `fetch*` caller to derive an envelope from) — but the top-level reason still said `nil`, which a consumer reads as "the derivation ran and succeeded." It ran and found nothing. Corpus probe: binanceus, fmfwio, kucoinfutures all hit this — `parse_dispatch` populated, zero fetcher entries.

**Fix applied:** `build_result/2` now computes `top_reason` — `if Enum.all?(parser_slots, fn {_k, v} -> is_nil(v) end), do: "no_fetcher_dispatch"` — and `Map.put`s that instead of a hardcoded `nil`. (When at least one slot resolved, `Enum.all?` is false and `top_reason` is `nil`, preserving the prior behaviour for the healthy case.) `"no_fetcher_dispatch"` was added to the closed `_unresolved_reason` vocabulary in three places that must stay in lockstep:
1. the `response_envelopes.ex` moduledoc (top-level reason section)
2. `SCHEMA.md` (the "Top-level `_unresolved_reason`" line)
3. `test/integration/cached/schema_v4_emit_cached_test.exs` — the corpus-wide allowlist assertion, expanded from `[nil, "not_yet_derived"]` to `[nil, "not_yet_derived", "no_fetcher_dispatch"]` with an explanatory comment.

---

## Regression tests added

`test/ccxt_extract/normalization/response_envelopes_test.exs` — **+12 tests across 5 describe blocks**, one per finding:

- `"audit F1 — plural parser names route to their parser-type slot"` (3) — `parseTickers` / `parseOHLCVs` / `parseDepositAddresses` each route into their slot.
- `"audit F2 — inline this.safe*(response, …) as parser arg"` (2) — inline `safeList` / `safeValue` in the return expression resolve.
- `"audit F3 — response['k'] / response.k as parser arg"` (2) — both member-access shapes resolve the property as the envelope key.
- `"audit F4 — safeValue2 / safeList2 arity"` (3) — 3-arg (no default) keeps `k2` as a fallback key; 4-arg splits `k2` → fallback, `default` → default; `safeList2` mirrors.
- `"audit F5 — top-level _unresolved_reason when no fetcher dispatchers"` (2) — mutator-only `parse_dispatch` emits `"no_fetcher_dispatch"`; mixed dispatch with one live fetcher stays `nil`.

All reuse the existing test helpers (`identifier/1`, `literal/1`, `this_call/2`, `var_decl/2`, `return_stmt/1`, `parse_return/2`, `safe_list_binding/2`, `parse_entry/1`, `fetch_entry/2`, `multi_fetch_entry/1`) — no new fixture scaffolding.

---

## Findings noted / out of scope

### Sobelow skip-fingerprint staleness (regenerated here)

The pre-commit hook surfaced two low-confidence `Traversal.FileModule` sobelow findings in `lib/ccxt_extract/pipeline.ex` (`File.mkdir_p!` line 157, `File.write!` line 167). Root cause: **b860b44 itself** — Task 83b's 21-line `pipeline.ex` edit (making `fetch_methods.json` optional) shifted those call sites' line numbers, and `.sobelow-skips` fingerprints findings by line number, so the prior skip entries went stale. Not new findings, not a real vulnerability surface (the paths are derived from `Paths.out(...)`, not user input). Regenerated `.sobelow-skips` via `mix sobelow --mark-skip-all` — the documented project workflow for re-marking after a scan. In the audit's blast radius because the line shift originated in the very commit under audit.

### Pre-existing `StagedDiscoveries.stage!/1` test-infra flake — out of scope

`test/integration/cached/schema_v4_emit_cached_test.exs` intermittently fails in its `setup` block with `{:error, :eexist}` from `StagedDiscoveries.stage!/1` (`File.ln_s/2`) under concurrent test-suite execution. This is **pre-existing test-infra flakiness** that predates both commits in this range — the `:eexist` is thrown before any audited code executes, in a file (`test/support/staged_discoveries.ex`) that neither commit touched. Confirmed out of scope for this audit; not investigated further here.

### Codex's `binance` ticker callout — confirmed, folded into F1

Codex independently flagged the binance ticker envelope as broken; root cause is F1 (missing `parseTickers`). Not a separate finding — verifying F1's corpus impact confirmed binance flips from a `null` ticker slot to a populated envelope on the next pipeline rerun.

### Integration modules (`normalization.ex` / `pipeline.ex` / `schema.ex` / `discovery_loader.ex`) — clean

Read in full. `build/3` (was `build/2`) correctly threads `parse_methods_entry, fetch_methods_entry, opts`; the `build/1` shim is retained for callers that don't have a fetch entry. `pipeline.ex` makes `fetch_methods.json` optional via `missing_required = data.missing_files -- ["fetch_methods.json"]` — correct, the slice is new and not every corpus snapshot has it. `schema.ex` calls `Normalization.build(nil, nil)` for the stub path. No findings.

## Files touched

- `lib/ccxt_extract/normalization/response_envelopes.ex` — F1 routing table; F2/F3 `classify_return_first_arg/1` + `classify_non_identifier_return_arg/1` + `extract_response_member_key/1` + `extract_property_name/1` + `{:inline_binding, _}` threading; F4 `extract_key_binding/2` + `parse_remaining_args/2` + `literal_string_list/1`, `collect_fallback_keys/1` removed; F5 `build_result/2` `top_reason`; moduledoc vocab extended.
- `test/ccxt_extract/normalization/response_envelopes_test.exs` — `+12` regression tests (5 describe blocks, F1–F5).
- `test/integration/cached/schema_v4_emit_cached_test.exs` — `_unresolved_reason` allowlist expanded for `"no_fetcher_dispatch"` (F5).
- `SCHEMA.md` — top-level `_unresolved_reason` vocabulary documents `"no_fetcher_dispatch"` (F5).
- `.sobelow-skips` — regenerated via `mix sobelow --mark-skip-all` to refresh line-number fingerprints staled by b860b44's `pipeline.ex` edit (see above).

## Harness state at audit completion

- `mix format --check-formatted`: clean
- `time mix compile --warnings-as-errors`: clean
- `mix test.json --quiet test/ccxt_extract/normalization/`: 312/312 pass
- `mix credo --strict --format json` on the two touched normalization files: 0 issues
- `mix dialyzer.json --quiet`: 0 warnings (5 skipped pre-existing entries, 0 on touched files)
- `mix sobelow`: clean (skip fingerprints regenerated)

The pre-existing `StagedDiscoveries.stage!/1` test-infra flake (see "Findings noted / out of scope") is unrelated to this audit and was left as-is — it predates the commit range and lives in a file neither commit touched.

Excluded tags (`:extraction`, `:tier3_corpus`, `:flaky`) NOT verified this pass — none touched by the audit fixes. The `:eexist` flake in `schema_v4_emit_cached_test.exs` was a hard pre-commit blocker; mitigated here via `async: false`, deeper fix filed as ROADMAP Task 136. It is pre-existing test-infra contention, not a regression from this commit or these fixes.
