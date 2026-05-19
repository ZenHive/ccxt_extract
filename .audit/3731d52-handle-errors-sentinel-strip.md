# audit(3731d52) — handle_errors function-sentinel strip

**Range:** 3731d52
**Subject:** json updates, bug fix
**LOC:** 287+ / 118- (114 files, ~30 LOC substantive in `lib/ccxt_extract/handle_errors.ex`; rest is corpus regen + test file)
**Touches lib/:** yes (`handle_errors.ex`)
**Classification:** full audit
**Reviewers:** Claude + Codex (gpt-5-codex, read-only)
**Verdict:** has-findings (all auto-applied; one discuss-trivial preserved by design)

## Context

Adds `strip_function_sentinels/1` family to drop QuickBEAM's `"__function:<ClassName>"` markers from CCXT's class-constructor `httpExceptions` / `exceptions` values at the extraction boundary. The flat-parents lookup in `contract_test.check_error_classes_covered_by_hierarchy` does bare-string match against `class_hierarchy.flat_parents`, so the sentinel couldn't resolve. Fix lives at `handle_errors.ex:111-130`. Includes a new 144-line `handle_errors_load_describe_test.exs` covering flat/nested/3-level/passthrough/empty-suffix/non-map cases.

## Findings table (synthesized)

| # | Pri | Cat | File:Line | Description | Source |
|---|---|---|---|---|---|
| A11 | 6 | duplication | `lib/ccxt_extract/handle_errors.ex` | TWO independent sentinel-strip implementations: new `strip_function_sentinels/1` hardcoded `"__function:"`; existing `normalize_class_name/1` used `@function_sentinel "__function:"` module attribute. Drift risk on any future change to QuickBEAM's sentinel format. | Codex |
| A17 | 5 | doc-gap | `CHANGELOG.md` e17b9c6 corpus refresh entry | "the fix lands in the follow-up commit by stripping the `__function:` prefix" — present tense after fix already landed in this same commit. | Codex+Claude |
| A20 | 3 | bug-edge | `lib/ccxt_extract/handle_errors.ex strip_function_sentinel_value/1` | List values not traversed. Trigger: `%{"exact" => %{"X" => ["__function:Foo"]}}` would pass through unchanged. (CCXT shape doesn't currently produce list values here; defensive coverage gap.) | Codex+Claude |
| A21 | discuss-trivial | bug-edge | `lib/ccxt_extract/handle_errors.ex` line 128 | Double-prefix `"__function:__function:Foo"` strips exactly once, leaving `"__function:Foo"`. Codex flagged as potential miss. **Resolution:** preserved by design — the empty-suffix test (`"__function:"` alone is preserved verbatim) pins the "strip exactly one prefix, never compose" semantics. Documented inline in the strip-helper comment. | Codex (deferred to design comment) |
| A23 | 4 | doc-gap (record-only) | git commit message | "json updates, bug fix" undersells a substantive wire-format extraction fix + 144-LOC test file. Codex + Claude both flagged. Cannot be amended post-merge — surfaced only for future reference. | Codex+Claude |

## Codex verdict

**Sentinel-strip correctness:** The main path is correct for `nil`, non-string values, nested maps, bare class names, and empty `"__function:"` values (tested directly). Gaps: list traversal (no clause), double-prefix (strips once — by design). No evidence the same normalization is needed in sibling extractors (parse_methods, sign_method, throw_dispatches).

## Actions applied

- A11: `@function_sentinel "__function:"` moved to top of module (line ~106), used in both `strip_function_sentinel_value/1` and `normalize_class_name/1` — single source of truth.
- A17: CHANGELOG rephrased to past tense + explicit commit reference.
- A20: List traversal clause added: `defp strip_function_sentinel_value(list) when is_list(list), do: Enum.map(list, &strip_function_sentinel_value/1)`.
- A21: Strip helper comment documents the single-strip-by-design invariant.

## Notes

The commit-message hygiene observation (A23) is the more interesting structural finding: substantive wire-format extraction fixes deserve `scope: description` subjects so future audit-reviews can dispatch tiny-vs-full classification correctly. "json updates, bug fix" routed correctly here only because the LOC + lib/ touch threshold caught it.
