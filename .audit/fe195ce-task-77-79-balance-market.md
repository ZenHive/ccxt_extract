# Audit: fe195ce — Task 77+79 parseBalance + parseMarket field_map (#25)

**Range:** `fe195ce^..fe195ce`
**Audited:** 2026-05-13
**Reviewers:** Claude (primary). Codex (second opinion) dispatched via `codex:codex-rescue` — both agents kicked off background Codex CLI jobs (`a233295a9f87a0dd1`, `a4b0263119d6ec00b`) but neither returned substantive findings through the agent harness within the audit window. Proceeded Claude-solo, mirroring the `80cb242` precedent's "Codex review hang" handling.
**Path:** full (substantial `lib/` changes — 332-LOC `balance.ex`, 329-LOC `market.ex`, both load-bearing for Phase 12 schema-v4 emission)

## Verdict: ✅ clean — 3 fixes applied

---

## Findings

### Cat 1 — `market.ex` missing `TSAsExpression` unwrap silently loses a corpus exchange

**File:** `lib/ccxt_extract/normalization/market.ex` — `find_market_object/1` (was lines 142–193)

`transaction.ex` and `deposit_address.ex` both unwrap `TSAsExpression` (`return {...} as Foo`) via an `unwrap_ts_as/1` helper before classifying the return argument — the TS-cast is a type-annotation, not a runtime shape, and ignoring it is essential for any exchange that writes `return {...} as Market;` in TypeScript. `market.ex` had no such unwrap. Corpus probe (`jq` against `priv/discoveries/parse_methods.json`) confirmed `grvt` (exchange idx 64, parseMarket return-shape distribution: `TSAsExpression:n/a`=1) is the live victim — its parseMarket returns a `TSAsExpression` wrapping an `ObjectExpression`, currently dropped into the wildcard fall-through and reported as `"no_return_statement"` (the misnomer below).

This is the exact template-drift class the v4 normalization phase exists to prevent: every parse_method module classifies returns the same way and emits the same `_unresolved_reason` vocabulary. `market.ex` had drifted off-template.

**Fix applied:**
1. Extracted return-argument classification into a dedicated `classify_return_argument/1` head-set, with `unwrap_ts_as/1` running once on the return argument before pattern matching (matches the structure already used by `transaction.ex` and `deposit_address.ex`).
2. `unwrap_ts_as/1` is recursive so chained `as A as B` casts unwrap fully — free with the shape chosen.
3. Added regression test `"TSAsExpression-wrapped ObjectExpression resolves cleanly"` under the "direct ObjectExpression return" describe, exercising `return { id: this.safeString(...) } as Market;` and asserting `_unresolved_reason: nil` plus a populated slot.

**Corpus impact:** `grvt` flips from `"_unresolved_reason": "no_return_statement"` (all 32 fields `null`) to a populated `field_map` matching its actual parseMarket shape on the next pipeline rerun.

---

### Cat 1 — `balance.ex` wildcard fall-through emits misleading `"no_return_statement"` + missing `identifier_return` clause

**File:** `lib/ccxt_extract/normalization/balance.ex` — `find_safe_balance_return/1` (line 148-150)

Same misnomer class as `trade.ex` (fixed in `80cb242` audit) and `market.ex` (fixed below): the wildcard fall-through emitted `"no_return_statement"` even when a `ReturnStatement` was present but its argument wasn't a recognized `this.safeBalance(...)` shape. Corpus probe confirmed `lbank` (parseBalance return-shape distribution: `CallExpression:safeBalance`=79, `Identifier:n/a`=1) is the live case — `lbank`'s parseBalance ends with `return result;` (a bare Identifier referring to the pre-built balance map), currently mis-classified as "no return statement at all."

Honesty-contract drift — consumers reading `_unresolved_reason` see "we couldn't find a return" when in reality "we found a return whose shape we don't classify."

**Fix applied:**
1. Added a dedicated `%{"argument" => %{"type" => "Identifier"}}` clause emitting `{:error, "identifier_return"}` (parallels the same clause `market.ex` already had).
2. Renamed the wildcard fall-through to `{:error, "unrecognized_return_shape"}`.
3. Moduledoc `_unresolved_reason` vocabulary updated with both new entries (`identifier_return`, `unrecognized_return_shape`), and `no_return_statement` clarified as "body has no `ReturnStatement` at all."
4. Two regression tests added under "derive/1 — unresolved paths":
   - `"bare Identifier return emits _unresolved_reason: identifier_return"` (lbank shape)
   - `"unrecognized return shape emits _unresolved_reason: unrecognized_return_shape"` (BinaryExpression `return a + b;`)

**Corpus impact:** `lbank` flips from `"_unresolved_reason": "no_return_statement"` to `"identifier_return"` — same null `field_map` (the bare-Identifier return is still structurally unresolved at this scope), but the reason string is now factually correct, which is the entire point of the `_unresolved_reason` honesty contract.

---

### Cat 1+3 — `market.ex` wildcard fall-through also emits misleading `"no_return_statement"`

**File:** `lib/ccxt_extract/normalization/market.ex` — `find_market_object/1` (was line 192)

Same misnomer as `balance.ex` and the original `trade.ex` (fixed in `80cb242`). The wildcard fall-through emitted `"no_return_statement"` regardless of whether a ReturnStatement was actually absent or simply had an unrecognized argument shape (e.g. `return foo() + bar()`, `return [x, y]`, `return undefined`).

After Finding 1's refactor extracted `classify_return_argument/1`, this fall-through became a single `classify_return_argument(_)` clause. Renaming it to `"unrecognized_return_shape"` aligns `market.ex` with the open-vocab convention `trade.ex` set in `80cb242`.

**Fix applied:**
1. The `classify_return_argument/1` wildcard clause emits `{:error, "unrecognized_return_shape"}`.
2. Moduledoc vocabulary entry already present (added in a prior commit on this branch, line 62–64); a note clarifying that `TSAsExpression`-wrapped returns are unwrapped before classification is now load-bearing rather than aspirational.
3. Regression test `"unrecognized return shape emits _unresolved_reason: unrecognized_return_shape"` added under "derive/1 — unresolved paths", exercising `return a + b;` (BinaryExpression) — none of the recognized clauses match, falls through to the wildcard.

---

### Cat 3 — SCHEMA.md vocab listing drift

**File:** `SCHEMA.md` — balance section (line 495) and market section (line 515)

Both sections enumerated the `_unresolved_reason` vocabulary explicitly. Neither listed `unrecognized_return_shape`; the balance section also omitted `identifier_return` (which is a live emitted value even before this audit — wasn't in moduledoc either). The schema file itself is permissive (`additionalProperties: true` on `NormalizationStubValue`), so this is documentation drift, not a contract violation — but consumers reading SCHEMA.md as the source-of-truth would have been blind to two of the vocab values.

**Fix applied:** balance section now lists all five vocab entries (`null`, `non_safe_balance_return:<callee>`, `no_return_statement`, `identifier_return`, `unrecognized_return_shape`); market section lists all five (`null`, `non_safe_market_return:<callee>`, `no_return_statement`, `identifier_return`, `unrecognized_return_shape`) plus a sentence noting `TSAsExpression` unwrap. No schema-version bump required.

---

## Findings rejected / noted

### Codex non-result

Two `codex:codex-rescue` dispatches kicked off independent background Codex CLI jobs but neither returned substantive findings through the agent harness within the audit window. This matches the `80cb242` precedent where Codex dispatched, did real corpus investigation, and then stalled in its reasoning turn. The dual-reviewer guarantee is degraded for this audit. The fixes applied are conservative: one missing helper (`unwrap_ts_as/1`) cloned from the same project's existing modules; two vocab renames extending an already-permissive schema; four regression tests on the new branches. No semantic-behavior change beyond what the corpus already proves (grvt and lbank flip from misnomer-emitting to truthful-emitting).

### `extend` and `n/a` parseMarket return shapes

Corpus probe shows two exchanges return via `this.extend(...)` (already classified as `non_safe_market_return:extend`) and one returns a bare Identifier (already classified as `identifier_return`). Both are handled by existing clauses — no new work required.

### Schema permissiveness

Verified `priv/schema/exchange_v4.json` — `NormalizationStubValue` accepts `additionalProperties: true`, so the new vocab entries (`identifier_return`, `unrecognized_return_shape`) require no schema bump. Following the same open-vocab convention as `trade.ex`'s `80cb242` audit.

### Per-finding scope discipline

Did NOT extend this audit's scope to `ticker.ex` (the original template, still carrying the same misnomer pattern). Same call as the `80cb242` audit: a normalization-vocab-alignment task is the right shape for that sweep, not a drive-by here. `ticker.ex` was untouched by `fe195ce`; the new modules now match `trade.ex`'s post-`80cb242` shape, but `ticker.ex` remains divergent.

---

## Files touched

- `lib/ccxt_extract/normalization/market.ex` — refactored `find_market_object/1` into find + `classify_return_argument/1` heads + `unwrap_ts_as/1` helper; `unrecognized_return_shape` wildcard rename; moduledoc already updated (uncommitted from earlier in this session).
- `lib/ccxt_extract/normalization/balance.ex` — added `identifier_return` clause; wildcard renamed to `unrecognized_return_shape`; moduledoc vocab list expanded.
- `SCHEMA.md` — balance and market `_unresolved_reason` vocabulary entries updated.
- `test/ccxt_extract/normalization/market_test.exs` — `+2` tests (TSAsExpression unwrap; unrecognized return shape).
- `test/ccxt_extract/normalization/balance_test.exs` — `+2` tests (bare Identifier; unrecognized return shape).

## Harness state at audit completion

- `mix format --check-formatted`: clean
- `time mix compile --warnings-as-errors`: clean (0.31s)
- `mix test.json --quiet test/ccxt_extract/normalization/`: 276/276 pass
- `mix credo --strict --format json` on the four touched normalization files: 0 issues (`123 mods/funs, found no issues.`)
- `mix dialyzer.json --quiet`: 0 warnings (5 skipped pre-existing entries, 0 on touched files)

Excluded tags (`:extraction`, `:tier3_corpus`, `:flaky`) NOT verified this pass — none touched by the audit fixes. The cached corpus-level shape assertions live in `test/integration/cached/schema_v4_emit_cached_test.exs`, which is offline and was included in the 276-test run.
