# Normalization Module De-duplication — Findings & Task Spec

> Standalone doc so it doesn't collide with the in-flight ROADMAP.md rework.
> Fold into ROADMAP.md (or wherever it lands) once the rework settles.

## Purpose

Verify whether the `lib/ccxt_extract/normalization/` clone cluster (ExDNA: 30 clones,
1636 nodes) is a templated module family that should collapse into one shared
classifier — and if so, scope the refactor.

## Method

1. `mix ex_dna` — textual clone detection. Flagged 30 clones in `normalization/`.
2. `mix reach.check --smells` + `mix reach.map --coupling lib/ccxt_extract/normalization/`
   — structural / graph analysis.
3. Manual full read of 4 of the 8 family modules: `order.ex`, `trade.ex`,
   `position.ex`, `ticker.ex`. The remaining 4 (`market.ex`, `balance.ex`,
   `deposit_address.ex`, `transaction.ex`) appear in the same ExDNA clusters but
   were not read line-by-line — read them during the refactor itself.

`response_envelopes.ex` is **not** in the clone clusters — treat it as outside
this family. `ohlcv.ex` appears in exactly one family-wide clone (a mass-32 block
common to all 9 `normalization/` modules) but in none of the pairwise
order/trade/position clusters — its family membership is marginal; confirm during
the refactor whether it joins the shared engine or stays standalone.

## Reach results

**Coupling (`normalization/`, 10 modules):** every module has
`afferent = 0 / efferent = 0 / instability = 0.0`, zero cycles. The modules never
call each other — they are independent siblings. 228 functions, **all classified
`pure`**. No shared state, no effects, no cycle risk → extraction is mechanically
low-risk.

**Smells:** Reach's `behaviour_candidate` detector fired once — and **not** on the
normalization family. It flagged `Describe / LoadMarkets / SigningFixtures /
UrlTemplates` sharing public `extract/1`, `extract_one/2`, `write!/2`. Only 4
findings landed in `normalization/`, all local nits (none about cross-module
duplication).

**Why Reach and ExDNA disagree:** ExDNA matches token sequences regardless of
visibility. Reach's `behaviour_candidate` keys on shared *public* callback sets.
The normalization family's only public surface is `derive/1` + `unified_fields/0`;
the 30 clones are all `defp`. So the duplication is **private implementation
duplication, not a shared public contract** — a `@behaviour` is the wrong tool
here. A shared module (plain helper module, or a `use` macro injecting the
private engine) is the right one.

## Verdict: mostly-but-not-purely vocab-divergent

The hypothesis ("divergence is vocab-only") is **~85% confirmed**. ~20+ functions
are byte-identical across `order` / `trade` / `position`
(`build_result/2`, `key_from_property/1`, `classify_scalar_field/2`,
`classify_timestamp_field/2`, `classify_enum_field/2`, `to_lower_chain?/1`,
`safe_call?/1`, the whole `classify_ternary` → `accumulate_enum_map` →
`finalize_enum_map` chain, `resolve_then_classify/2`, `build_slot/3`,
`lookup_binding/2`, `unresolved/1`, …). But the divergence is **not** purely
vocab. Three buckets:

### Bucket A — legitimate parameterization axes (4)

These are real per-type data, and the shared engine must take them as parameters:

| Axis | order | trade | position | ticker |
|---|---|---|---|---|
| `@unified_fields` | 26 fields | 13 | 28 | 22 |
| safe-call method vocab | `@scalar_vocab` (+`safeBool`) | `@scalar_vocab` (+`safeStringLower`) | `@scalar_vocab` (+`safeBool`) | `@slot_vocab` (no enum/bool) |
| wrapper method + reason prefix | `safeOrder` / `non_safe_order_return:` | `safeTrade` / `non_safe_trade_return:` | `safePosition` / `non_safe_position_return:` | `safeTicker` / `non_safe_ticker_return:` |
| field categories | `@enum_fields` / `@structurally_null` / `@scalar_fields` | + `@nested_fields` | `@enum_fields` / `@structurally_null` / `@scalar_fields` | none (collapsed) |

### Bucket B — legitimate feature divergences (2)

Real capability differences, must stay parameterizable (not all types need them):

- **Shape-discriminator detection** (`shape_discriminator_count/?` +
  `discriminator_test?/1` ×4 clauses). Present in `order` + `trade`; **absent** in
  `position` (moduledoc: "0 of 49 parsePosition bodies have discriminators") and
  `ticker`.
- **Nested `fee` sub-slots** (`classify_fee_field`, `build_fee_sub_map`,
  `classify_fee_subfield`, `currency_slot`, `trace_currency_wire_key`, plus a
  `safeCurrencyCode` clause on `classify_safe_call`). **`trade` only.**

### Bucket C — likely DRIFT, needs a decision (3) ⚠️

This is the real payoff of the refactor. These look like copy-paste-adapt drift —
a fix or tweak applied to one module and not back-ported. Consolidating forces
each to be either justified-and-kept or recognized-as-a-bug-and-fixed:

1. **Ternary operator set.** `order` + `position` accept `op in ["===", "=="]`;
   `trade` accepts `op in ["===", "!==", "==", "!="]`. Does `trade` legitimately
   need `!==`/`!=` and the others don't — or did `trade` get a fix the others
   missed?
2. **First-vs-last `ReturnStatement`.** `ticker` uses `Enum.find` (FIRST return);
   `order` / `trade` / `position` use `Enum.filter |> List.last` (LAST return,
   with a comment about early-return guards). `ticker` predates the others
   (Task 74 vs 75/76/80) — almost certainly stale. Should `ticker` move to
   last-return?
3. **Misleading error fallback.** `trade`'s `find_safe_trade_object` `_ ->` clause
   returns `"unrecognized_return_shape"`; `order` / `position` / `ticker` return
   `"no_return_statement"` for the same case — i.e. they report "no return" when a
   return *does* exist but has an unrecognized shape. `trade` is correct; the
   other three look buggy.

## Recommended refactor shape

A `use`-macro engine, **not** a `@behaviour` (no public contract to formalize):

```
CcxtExtract.Normalization.Classifier   # the shared engine
  - holds the ~20 identical private functions
  - `use` macro injects them into each type module
  - each type module supplies: @unified_fields, the method vocab,
    the wrapper-method name + reason prefix, field-category lists,
    and opt-in flags for discriminator detection / nested-fee handling
```

Each per-type module shrinks to its moduledoc + attribute block + `derive/1` +
`unified_fields/0` + any genuinely type-specific clause (`trade`'s fee handling).

**Do not** mechanically extract ExDNA's 30 `shared_*` defps — that scatters the
engine without naming the seam. One engine module, parameterized.

## Risk assessment (Reach-backed)

- **Low.** All 228 family functions are pure; zero inter-module coupling; zero
  cycles. No state to thread, no effect ordering to preserve, no risk of
  introducing a cycle.
- The only real risk is mishandling Bucket B/C — collapsing a feature divergence
  that should stay divergent, or silently picking one side of a drift. The task
  must treat Bucket C as explicit decisions, not merge artifacts.
- `:extraction`-tagged integration tests + `mix ccxt_extract.determinism_check`
  are the safety net — output must stay byte-identical post-refactor (Bucket C
  fixes excepted, which by definition change output for some exchanges).

## Known limitation — Reach clone-drift detection is non-functional here

The original plan was to wire `clone_analysis` (ExDNA provider) into a `.reach.exs`
so `mix reach.check --smells` would auto-surface Bucket-C-style structural drift
(`return_contract_drift`, `side_effect_order_drift`, etc.). **It does not work in
this version pair (Reach 2.3.2 + ex_dna 1.5.1)** — verified empirically:

- ExDNA detection itself is fine — `Reach.CloneAnalysis.analyze/2` returns 50 clones.
- But Reach's fragment→function resolution is broken: for every ExDNA-reported
  clone fragment, `Reach.Project.Query.find_function_at_location/3` returns nil.
  Each fragment resolves `module` (coarse line-range scan) but `function` / `arity`
  / `return_shapes` / `effect_sequence` stay nil/empty.
- `Reach.Smell.Checks.CloneConsistency.meaningful_fragments/1` hard-filters on
  `module && function && file && line`, so it drops every fragment →
  `CloneConsistency` returns 0 findings, unconditionally. `min_similarity` /
  `min_mass` tuning is irrelevant — the seam is structurally broken.

A `.reach.exs` was added and reverted (it was inert: the `clone_analysis` block
wired a broken detector, the `smells` block only restated Reach's defaults).
**Consequence:** the Bucket C drift items above remain a *manual* finding — this
doc is the record. Worth a possible upstream bug report to Reach.

Reach capabilities that DO work and need no config: `mix reach.map --coupling`
and the `behaviour_candidate` / `fixed_shape_map` smells (`--smells` runs on
defaults).

## Open questions for the roadmap rework

1. **Bucket C resolution** — do the 3 drift items get fixed *as part of* the
   dedup task, or split into separate bug entries? (They change extraction output
   for some exchanges, so they're not pure refactor.)
2. **Scope** — read the other 4 family modules (`market`, `balance`,
   `deposit_address`, `transaction`) before sizing; they may surface more
   Bucket-C drift.
3. **Sibling task** — the `Describe / LoadMarkets / SigningFixtures / UrlTemplates`
   `write!/2` + `extract/1` behaviour candidate Reach flagged is a *separate*,
   genuinely-behaviour-shaped task. Worth its own entry.
4. **Smaller wins, unrelated to this family** — `render_ast/1` triplicated across
   `error_dispatch` / `sign_dispatch` / `throw_dispatches` (ExDNA #1/#16/#35);
   clean pure-function extraction, no decision needed.
