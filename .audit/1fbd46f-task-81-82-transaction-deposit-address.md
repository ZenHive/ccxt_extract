# Audit: 1fbd46f — Task 81+82 parseTransaction + parseDepositAddress field_map (#24)

**Range:** `1fbd46f^..1fbd46f`
**Audited:** 2026-05-13
**Reviewers:** Claude (primary). Codex (second opinion) dispatched via `codex:codex-rescue` — kicked off a background Codex CLI job (`a233295a9f87a0dd1`) but did not return substantive findings through the agent harness within the audit window. Proceeded Claude-solo, mirroring the `80cb242` precedent.
**Path:** full (substantial `lib/` — 330-LOC `transaction.ex`, 263-LOC `deposit_address.ex`, both produced from the same template established by `trade.ex` post-`80cb242` audit)

## Verdict: ✅ clean — 1 fix applied (doc only)

This commit landed in lockstep with `fe195ce` (Task 77+79). The two modules audited here are well-behaved: both correctly unwrap `TSAsExpression` before classifying the return argument (which `market.ex` was missing — see the `fe195ce` audit). Both use the open-suffix `"non_object_return:<type>"` vocab convention which means new return shapes flow through with their type-name attached rather than collapsing to a misleading reason. The only substantive finding is one undocumented vocab entry that the implementation already emits.

---

## Findings

### Cat 3 — `"non_object_return:unknown"` vocab entry undocumented in moduledoc

**Files:**
- `lib/ccxt_extract/normalization/transaction.ex` — line 149 (`{:error, "non_object_return:unknown"}`)
- `lib/ccxt_extract/normalization/deposit_address.ex` — line 128 (same)

Both modules emit `"non_object_return:unknown"` in a corner of the classification: when the unwrapped `last_return["argument"]` has NO `"type"` field at all (e.g. a bare `return;` with no value, or an argument node missing the type key for some other reason). The moduledoc's `_unresolved_reason` vocabulary section documented only the open-suffix form `"non_object_return:<type>"` — a reader scanning for `:unknown` in the moduledoc would not find it, and a downstream consumer doing strict closed-vocab matching would have one undocumented value to handle.

Zero corpus impact (`bare `return;` in `parseTransaction` is unheard-of and `parseDepositAddress` parity is the same), but the vocabulary contract should be exhaustive — the implementation emits a distinct value precisely so the cause is inspectable, and the moduledoc should reflect that.

**Fix applied:** Both moduledocs now list `"non_object_return:unknown"` explicitly under the `_unresolved_reason` vocabulary section, with a one-line explanation that this is the "argument has no `type` field" edge case (typically `return;` with no value) emitted distinctly so it doesn't masquerade as a typed shape.

No code change. No SCHEMA.md change (the SCHEMA.md sections for transaction and deposit_address already use the open-suffix form, which covers this entry).

---

## Findings rejected / noted

### Codex non-result

The `codex:codex-rescue` agent for this range returned `status: completed` confirming background Codex dispatch but no substantive findings came back through the agent harness. Same handling as the `fe195ce` audit and the `80cb242` precedent. The dual-reviewer guarantee is degraded; the fix applied is a one-line moduledoc clarification with no behavior change.

### Template alignment

`transaction.ex` and `deposit_address.ex` both follow the post-`80cb242` `trade.ex` template — separate "find return" from "classify argument," unwrap `TSAsExpression` before classification, emit type-suffixed reason strings, never emit `"no_return_statement"` from a wildcard fall-through. The `market.ex` divergence (TSAsExpression unwrap missing, wildcard misnomer) audited in `fe195ce` is the exception, not the rule — Task 81+82's modules are the well-formed template implementations.

### `extras` shape parity

Verified the `extras` list shape in both modules matches `trade.ex` and `ticker.ex` — `[%{"unified_key" => ..., "key" => ..., "coercion" => ...}]`. No drift.

### `@spec` coverage

Spot-checked both files for the `@spec`-on-every-defp mandate. Coverage is solid — both modules ship with full `@spec` annotation on all `defp` heads, consistent with the post-`80cb242` `trade.ex` baseline.

---

## Files touched

- `lib/ccxt_extract/normalization/transaction.ex` — moduledoc `_unresolved_reason` vocabulary entry added for `"non_object_return:unknown"`.
- `lib/ccxt_extract/normalization/deposit_address.ex` — same.

No test changes (the new vocab entry documents existing emission, not new behavior; existing `non_object_return:<type>` tests already exercise the surrounding clause).

## Harness state at audit completion

- `mix format --check-formatted`: clean
- `time mix compile --warnings-as-errors`: clean (0.31s)
- `mix test.json --quiet test/ccxt_extract/normalization/`: 276/276 pass (audit-scope run also covers the `fe195ce` fixes)
- `mix credo --strict` on the four touched normalization files: 0 issues
- `mix dialyzer.json --quiet`: 0 warnings on touched files (5 skipped pre-existing entries)

Excluded tags (`:extraction`, `:tier3_corpus`, `:flaky`) NOT verified this pass — none touched by this commit's fixes.
