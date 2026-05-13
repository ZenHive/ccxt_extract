# Audit: 80cb242 — Task 76 parseTrade field map (#22)

**Range:** `80cb242^..80cb242`
**Audited:** 2026-05-13
**Reviewers:** Claude (primary). Codex (second opinion) dispatched but hung in reasoning turn for 30+ min after completing corpus investigation — cancelled and proceeded Claude-solo. Investigation evidence preserved in Codex log; conclusions never written.
**Path:** full (770 LOC `lib/`, 706 LOC test — `lib/` touched, normalization stub)

## Verdict: ✅ clean — 3 fixes applied

---

## Findings

### Cat 1 — `find_safe_trade_object/1` fall-through emits misleading `"no_return_statement"`

**File:** `lib/ccxt_extract/normalization/trade.ex` — `find_safe_trade_object/1` (line 192)

`find_safe_trade_object/1` filters the body's `ReturnStatement` nodes and takes the last one. The genuine "no return at all" branch (`nil ->`) correctly emits `"no_return_statement"`. The wildcard fall-through (`_ ->`) ALSO emitted `"no_return_statement"` — but it fires when `last_return` IS a `ReturnStatement` whose argument is not a recognized `this.<method>(...)` CallExpression (e.g., `return Trade.from(x)`, `return { ... }`, `return undefined`). The reason string lied: there WAS a return statement; we just didn't recognize its shape.

Honesty-contract drift, not a behavior bug — every caller that reads `_unresolved_reason` sees a factually misleading classification. Zero corpus impact in the current 93-exchange corpus (no parseTrade has shipped a non-`this.safe*` top-level return), but the contract was wrong.

The previous Task 74 audit (`329269f`) flagged this same pattern in `ticker.ex` and chose not to fix it ("would require a schema and consumer contract change"). With v4 schema's `additionalProperties: true` on `_unresolved_reason` and the moduledoc-declared open-vocab convention, a new top-level vocab entry costs nothing structural.

**Fix applied:**
1. Renamed the fall-through error to `"unrecognized_return_shape"`.
2. Added the new vocab entry to the moduledoc, clarifying the boundary between `no_return_statement` (body has no ReturnStatement at all), `non_safe_trade_return:<callee>` (return calls `this.<other>`), and `unrecognized_return_shape` (return exists but its argument shape isn't recognized).
3. Added regression test `"non-this CallExpression return emits unrecognized_return_shape"` exercising `return Trade.from(x)`.

**Inherited debt flagged:** `lib/ccxt_extract/normalization/ticker.ex` (lines 97, 125) still carries the original misnomer. Task 74's audit explicitly punted; this audit does NOT extend scope to ticker.ex (not touched by Task 76's commit). Follow-up candidate — a dedicated ticker normalization vocab-alignment task is the right shape, not a drive-by here.

---

### Cat 2 — Missing `@spec` on ~17 private helpers (project-mandate divergence)

**File:** `lib/ccxt_extract/normalization/trade.ex`

The user's global Elixir mandate (`development-philosophy.md` § "Specs — Mandate: every function gets a `@spec` — `def` and `defp` alike"). `ticker.ex` (the template) ships with ~14 of its ~16 defps spec'd. `trade.ex` shipped with ~23 of its ~40 defps spec'd — coverage drifted to ~58% in the new enum/fee/binding-lookup helper paths (`to_lower_chain?`, `safe_call?`, `build_enum_from_*`, `classify_eq_test`, `array_index?`, `classify_string_enum_test`, `resolve_to_safe_call`, `accumulate_enum_map`, `descend_or_finalize`, `finalize_enum_map`, `literal_value`, `same_safe_call?`, `build_fee_sub_map`, `classify_fee_subfield`, `currency_slot`).

Hygiene drift — not a behavior bug. Specs on the enum-map walker and resolution helpers pin the union return shapes (`{:enum_map, %{...}} | :error`, `{:enum_lhs, map(), String.t()} | :bool_flag | :numeric_code | :char_code | :unknown`) that Dialyzer can't always infer in the multi-clause pattern-match chains.

**Fix applied:** Added 17 `@spec` annotations covering all previously-unspec'd defp families. Specs match the actual call-site contracts (verified via Dialyzer — 0 warnings post-add).

---

### Cat 4 — No test for `resolve_to_safe_call/2` Identifier-binding clause

**File:** `test/ccxt_extract/normalization/trade_test.exs`

`resolve_to_safe_call/2` has three clauses: direct `CallExpression` (line 519), `Identifier` resolved via binding (line 523), wildcard nil (line 530). The `Identifier`-binding clause handles the real CCXT pattern where a parseTrade does `const side = this.safeString(trade, 'side');` and then references `side === 'BUY' ? ...` inside the safeTrade return — the discriminator is bound, not inline. Binance, deribit, and several others use this shape for `side` / `type` / `takerOrMaker`.

The existing "Identifier binding lookup" describe covered the scalar field path (via `resolve_then_classify` → `resolve_identifier`) but not the enum-ternary discriminator path. The only enum tests exercised inline `safe = this_call(...)` discriminators (lines 358, 425). The Identifier-binding clause was reachable only via real corpus runs.

**Fix applied:** Added `"enum ternary where discriminator is an Identifier bound to a safe-call resolves"` test under the "enum fields" describe. Exercises the full chain: `var_decl` → `safe_trade_return` with nested ternary discriminating on the bound identifier → asserts `enum_map: %{"BUY" => "buy", "SELL" => "sell"}`.

---

## Findings rejected / noted

### Codex review hang

Codex dispatched at 08:23 UTC with the audit-review's mandatory second-opinion prompt. Codex did real evidence-grade investigation — read trade.ex, ticker.ex, ohlcv.ex, ast_helpers.ex, trade_test.exs, integration tests, exchange_v4.json, CHANGELOG.md; queried real corpus data via 12+ jq commands against `priv/discoveries/parse_methods.json` and `priv/output/{okx,deribit}.json` (last command completed 08:29 UTC). Then the reasoning step stalled — log frozen for 30+ minutes, Codex session ID `019e206f-85e9-78e3-8040-bb4da86e8b0c` stuck in pending-response without emitting findings. Cancelled at 08:59 UTC; proceeded Claude-solo.

The dual-reviewer guarantee is degraded for this audit. The hang is an infrastructure failure, not a substantive disagreement. The fixes applied are conservative (rename + vocab doc + tests + specs) — no semantic behavior change beyond the open-vocab-entry rename, which is a documented permissive expansion.

### Inherited ticker.ex `"no_return_statement"` misnomer

Same bug at `ticker.ex:97, 125`. Out of scope for Task 76 (ticker.ex untouched by this commit). Previous audit (329269f) discussed and punted. Now with the misnomer fixed in trade.ex, the two normalization modules carry divergent vocabularies. Follow-up candidate — a normalization vocab-alignment task that includes ticker.ex.

### Test isolation: `Mix.shell()` pin in this file

Not applicable — `trade_test.exs` doesn't exercise Mix.shell or `capture_io`. CLAUDE.md's Task 131 pattern is for shell-capturing tests; this file uses pure data fixtures.

### Schema permissiveness

Verified `priv/schema/exchange_v4.json:568-684` — `NormalizationStubValue` is `oneOf null/object` with `additionalProperties: true`. Adding `"unrecognized_return_shape"` to the open vocab does NOT require a schema bump. SCHEMA.md vocab list updated in scope below.

---

## Files touched

- `lib/ccxt_extract/normalization/trade.ex` — moduledoc vocab entry; fall-through error rename; 17 @spec annotations
- `test/ccxt_extract/normalization/trade_test.exs` — 2 regression tests (Cat 1 + Cat 4)

## Harness state at audit completion

- `mix compile --warnings-as-errors`: clean
- `mix test.json --quiet test/ccxt_extract/normalization/`: 103/103 pass (was 101 — +2 from new tests)
- `mix format --check-formatted`: clean on touched files
- `mix credo --strict --format json lib/ccxt_extract/normalization/trade.ex`: 0 issues
- `mix dialyzer.json --quiet`: 0 warnings (0 on `normalization/trade.ex`)

Excluded tags (`:extraction`, `:tier3_corpus`, `:flaky`) NOT verified this pass — none touched by the audit fixes.
