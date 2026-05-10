# Audit: 329269f — Task 74 parseTicker field map (#21)

**Range:** `329269f^..329269f`  
**Audited:** 2026-05-10  
**Reviewers:** Claude (primary) + Codex (second opinion)  
**Path:** full (762 LOC, `lib/` touched)

## Verdict: ✅ clean — 3 fixes applied

---

## Findings

### Cat 1 — Computed property key returns identifier name instead of nil

**File:** `lib/ccxt_extract/normalization/ticker.ex` — `key_from_property/1`

`key_from_property/1` matched `%{"key" => %{"name" => name}}` without checking the `"computed"` flag. In JavaScript AST, a computed property `{[dynKey]: val}` carries `"computed" => true` — the key is a runtime expression, not statically determinable. Without the guard, `key_from_property` returned `"dynKey"` (the variable name) instead of `nil`, potentially bleeding dynamic keys into `field_map` or `extras`.

Zero corpus impact (no computed property keys appear in real parseTicker ObjectExpressions in the 93-exchange corpus), but the contract was wrong.

**Fix applied:** Added `defp key_from_property(%{"computed" => true}), do: nil` as the leading clause.

**Codex agreement:** Yes (rated 7/10).

---

### Cat 4 — No test for computed property key path

**File:** `test/ccxt_extract/normalization/ticker_test.exs`

The `nil`-key guard path (introduced in the pre-merge fix commit) was tested via unbound Identifier and non-vocab coercion, but not via the computed property shape that triggered the Cat 1 finding above.

**Fix applied:** Added `"computed property key is skipped from both field_map and extras"` test in the `extras list` describe block. Asserts: extras is empty, all 22 field_map values are nil, dynamic identifier name doesn't bleed into any unified field.

---

### Cat 6 — CONSUMER_CONTRACT.md not updated

**File:** `CONSUMER_CONTRACT.md`

`parseTicker field map + coercion + enums` row was still `⬜` post-merge.

**Fix applied:** Flipped to `✅`.

---

## Findings rejected / noted

### Codex: safeStringN ArrayExpression key drops to nil (rated 8/10) — Disagreed

`this.safeStringN(ticker, ["open", "open24h"])` emits `nil` for that field because `build_slot/3` requires a `Literal` key argument. **By design** — the slot shape has a single `"key"` field and cannot represent multi-key lookups. `build_slot` falls through to honest null, consistent with `@moduledoc` and SCHEMA.md. No action.

### Discussion (pre-merge, carried): `find_safe_ticker_object` "no_return_statement" misnaming

The wildcard catch-all clause emits `"no_return_statement"` for return statements that don't match the `this.callee(...)` shape (e.g., `return ticker;`). Factually misleading but zero corpus impact. Not fixed — would require a schema and consumer contract change. Tracked as a potential ROADMAP refinement if a corpus exchange hits this path.

---

## Files touched

- `lib/ccxt_extract/normalization/ticker.ex` — computed key guard (1 clause added)
- `test/ccxt_extract/normalization/ticker_test.exs` — computed key regression test
- `CONSUMER_CONTRACT.md` — `parseTicker` row flipped ⬜ → ✅
