# Schema Versioning Contract

This document defines the stability promise for ccxt_extract's output format. Consumers (Elixir, Rust, Go, Python) rely on `schema_version` to know what they can safely depend on.

---

## The Contract

Every per-exchange JSON file and `_manifest.json` includes a `schema_version` field (e.g., `"1.0.0"`). This version follows **semver** (three components: `MAJOR.MINOR.PATCH`) with these rules:

| Change Type | Version Bump | Consumer Impact |
|-------------|-------------|-----------------|
| **Additive fields** — new nullable keys in existing sections | Patch (1.0.x) | Safe to ignore. Existing field access unaffected. |
| **Backward-compatible structural changes** — reorganized sections, renamed fields with temporary aliases that preserve old access paths | Minor (1.x.0) | Plan to update parsers. Old field access works during the alias period but aliases are eventually removed. |
| **Breaking changes** — removed fields, changed types, semantic changes to existing fields | Major (x.0.0) | Must update. Old parsers will fail or produce wrong results. |

**Enum fields are open sets.** Fields like `has` capabilities and AST node `type` values may gain new values at any version bump. Consumers must not exhaustively match these — use fallback/default branches.

### Consumer Guidance

**Check version on load.** Before parsing any exchange JSON, read `schema_version` and fail fast on incompatible data:

```python
# Python
data = json.load(f)
major = int(data["schema_version"].split(".")[0])
if major != 4:
    raise ValueError(f"Unsupported schema version: {data['schema_version']}")
```

```rust
// Rust
let major: u32 = data["schema_version"].split('.').next().unwrap().parse()?;
assert_eq!(major, 4, "Unsupported schema version");
```

```elixir
# Elixir
case data do
  %{"schema_version" => "4." <> _} -> :ok
  %{"schema_version" => v} -> raise "Unsupported schema version: #{v}"
end
```

**Handle unknown fields gracefully.** Patch versions may add new nullable keys. Consumers should ignore fields they don't recognize rather than failing on them.

**Pin to a major version.** Your consumer code targets a major schema version (currently 4). Within that major version, all changes are backward-compatible (minor bumps use aliases to preserve old access paths).

**v3 legacy fallback.** The v4 top-level reshape (`runtime`/`structure` → `endpoints`/`auth`/`errors`/`rate_limits`/`normalization`/`markets`/`testnet`/`raw`) is now the default published schema. v3 output remains reachable via `--schema-target=3` on `mix ccxt_extract.pipeline` and `mix ccxt_extract.update` as a legacy fallback; it is removed in Task 143. Consumers still on major version `3` should migrate — see [Version 4.0.0 — Current](#version-400--current).

---

## Version 3.3.0 — Superseded

**Status:** Superseded by v4.0.0 (released 2026-05-08, Task 73d, PR #9 / INE-64)

**JSON Schema:** `exchange_v3.json` (included in every output directory)

**Latest change:** Adds required `structure.transaction_classification` —
per-unified-endpoint write-side classification flags derived from CCXT's
unified-method naming convention. Map `unified_name → {transactional,
on_chain}` where:

  - `transactional` is `true` when the endpoint mutates exchange-side
    state (places, edits, or cancels orders, withdraws, transfers, sets
    leverage / margin mode, opens / closes positions, borrows / repays).
    `false` for `fetch*` reads.
  - `on_chain` is the strictly narrower flag — `true` only for endpoints
    that initiate a blockchain transaction the exchange broadcasts on the
    user's behalf (the `withdraw*` family). Internal exchange-to-exchange
    `transfer` stays off-chain. Every on-chain endpoint is transactional;
    the inverse is not true.

`null` permitted when no unified endpoint mappings were available to
classify (matches `unified_endpoints` null semantics). New
`TransactionClassificationEntry` `$def` in `exchange_v3.json` with
`additionalProperties: false`. `_provenance["/structure/transaction_classification"] = "derived"`.

v4's `endpoints.transaction_classification` slot is populated alongside
`endpoints.unified` — peer field, not nested, so consumers can read the
classification independently of the endpoint→interface mapping.

**Minor bump** because the key is now in `Structure.required` — strict
validators reject 3.2.0 output lacking it; permissive readers that
ignore unknown keys are unaffected. See the `TransactionClassificationEntry`
`$def` in `exchange_v3.json` for the full schema.

**Why this lands now:** consumers (ccxt_client, others) need a uniform
write-side gate before exposing endpoints in client APIs:

  - **`transactional` true** → prompt for confirmation, require API
    credentials, surface in audit logs.
  - **`on_chain` true** → enforce stronger gating (KMS / two-factor),
    treat as a blockchain-broadcast operation.

The flag was previously implicit in CCXT's naming convention; consumers
re-derived it (often inconsistently) per project. Crystallizing it once
into the spec eliminates that drift.

**Security gap — out of scope.** The classifier covers CCXT's **unified**
method namespace only. Non-unified raw broadcast endpoints — DEX flows
that expose blockchain transactions through helpers like `signL1Action` /
`signEIP712`, or implicit-API paths like `public_post_sendtx` /
`sendTxBatch` — do NOT appear in `transaction_classification`.
**Consumers MUST NOT treat `on_chain == false` (or absence) as a
sufficient safety gate for blockchain-broadcast operations.** Tracked
as **Task 73f** in [ROADMAP.md](ROADMAP.md) (OXC body-inspection
extension).

**Override-registry note.** The v3→v4 JSON-Pointer translation table
(`OverrideRegistry.@v3_to_v4_pointer_prefixes`) gained two new entries
in this release: `/structure/transaction_classification` →
`/endpoints/transaction_classification` (this task) and
`/structure/error_class_hierarchy` → `/errors/class_hierarchy`
(retroactive — Task 87 added the field but missed the translation
entry). Override files targeting either path now translate cleanly
under `--schema-target=4`.

---

## Version 3.2.0 — Superseded

**Released 2026-05-08, Task 87.**

**JSON Schema:** `exchange_v3.json` (included in every output directory)

**Latest change:** Adds required `structure.error_class_hierarchy` — CCXT's
exception class taxonomy (`BaseError → ExchangeError → ... →
AccountNotEnabled`) sourced from `priv/ccxt/ts/src/base/errorHierarchy.ts`
via OXC. Three-shape record:

  - `tree` — recursive map mirroring the source literal.
  - `flat_parents` — `class_name → parent_name` (root → `null`). O(1) parent.
  - `ancestors` — `class_name → [parent, ..., BaseError]`. O(1) ancestor chain.

Corpus-global data — every per-exchange JSON carries the same record
(matches `error_code_fields` / `throw_dispatches` colocation under
`structure`). `_provenance["/structure/error_class_hierarchy"] =
"derived"` — `flat_parents` and `ancestors` are pre-computed projections,
not literally in the source.

**Minor bump** because the key is now required in `Structure.required` —
strict validators will reject 3.1.0 output lacking it; permissive readers
that ignore unknown keys are unaffected. See the `ErrorClassHierarchy` and
self-recursive `ErrorClassHierarchyTree` `$defs` in `exchange_v3.json` for
the full schema.

**Why this lands now:** error-handling consumers (retry classifiers,
status-code mappers, "is this exception transient?" predicates) need the
full ancestor chain of every CCXT exception class — not just the leaf
class name. Extracting the tree once into a structured artifact lets every
consumer answer "is `RateLimitExceeded` a descendant of `NetworkError`?"
without reparsing CCXT source. Phase 13's `error_class_hierarchy`
companion (`13-classify` bundle) sits alongside the existing
`structure.handle_errors` (which pins which classes are raised by HTTP
status / body content / error-code branches). Two new contract invariants
gate the contract: `error_class_hierarchy_shape_valid` (intrinsic shape +
single root + walk agreement, cycle-safe) and
`error_classes_covered_by_hierarchy` (every class named in
`handle_errors.exceptions` / `http_exceptions` exists in `flat_parents`).

---

## Version 3.1.0 — Superseded

**Released 2026-05-07, Task 73b.** Adds required `runtime.request_headers` —
per-exchange `userAgent` and default `headers` from CCXT's resolved
`describe()` runtime data, surfaced as an always-emit wrapper `{user_agent:
string|null, default_headers: object<string, string>}`. Sourced via
QuickBEAM constructor instantiation (where the `deepExtend(super.describe(),
{...})` merge runs). `_provenance["/runtime/request_headers"] = "raw"`.

**Minor bump** because the key is now in `RuntimeData.required` — strict
validators will reject 3.0.0 output lacking it; permissive readers that
ignore unknown keys are unaffected. See the `RequestHeaders` `$def` in
`exchange_v3.json` for the full schema.

**Coverage:** 8/107 non-alias exchanges override `userAgent` (`bitstamp`,
`bittrade`, `coinbase` + 2 variants, `delta`, `hibachi`, `htx`); 4/107
override `default_headers` (`alpaca`, `coinbase`, `coinbaseinternational`,
`gate`). All others emit the empty wrapper — honest absence, not a guess.

**Out of scope (filed as Task 73e):** `bigone.ts` constructs its
`User-Agent` inside `sign()`; `okx.ts` mutates `this.headers` at runtime
via `setSandboxMode()`. Both blind spots need an OXC-side pass over
sign-method bodies — not visible to QuickBEAM's resolved-describe()
extraction path.

The previous `## Version 3.0.0` baseline documentation follows; the 3.1.0
addition is additive — consumers pinned to major version `3` continue to
read without change aside from the new required-field shape.

---

## Version 4.0.0 — Current

**Status:** Default published schema as of 2026-05-15 (Task 142). v4 is emitted by `mix ccxt_extract.pipeline` and `mix ccxt_extract.update` without any flag. v3 is available as a legacy fallback via `--schema-target=3`; it is removed in Task 143.

**JSON Schema:** `exchange_v4.json` (included in every output directory). `exchange_v3.json` remains available for the legacy fallback path.

**Why a major bump (vs additive v3.x):** the v4 cut reorganizes top-level sections from producer-shaped (`runtime` / `structure`) to consumer-shaped (`endpoints` / `auth` / `errors` / `rate_limits` / `normalization` / `markets` / `testnet` / `raw`). Additive v3.x can grow new keys but cannot reorganize without breaking; one migration cost in exchange for a coherent stable contract. Additive v3.x bumps that surface new corpus-global derived fields (e.g., 3.2.0's `error_class_hierarchy`) ship as needed; the breaking change deferred to v4 is the top-level reshape, not the freeze of every minor.

### Top-level reshape

| v3 path | v4 path | Notes |
|---|---|---|
| `runtime.symbols_index` | `markets.symbols_index` | Markets group |
| `runtime.symbol_patterns` | `markets.patterns` | Markets group (renamed for brevity) |
| `runtime.request_headers` | `auth.headers` | Headers belong to the auth surface |
| `runtime.url_templates` | `raw.url_templates` | Raw fallback (not consumer-facing primary) |
| `runtime.describe` | `raw.describe` | Raw CCXT describe — kept under `raw` for AST-level needs |
| `runtime.testnet_urls` | `testnet` (top-level) | Promoted out of `runtime`; small, distinct concern |
| `structure.sign_recipe` | `auth.sign_recipe` | Auth group |
| `structure.sign_method` | `auth.sign_method` | Auth group (raw AST fallback) |
| `structure.authenticated_sections` | `auth.authenticated_sections` | Auth group |
| `structure.handle_errors` | `errors.handle_errors` | Errors group |
| `structure.unified_endpoints` | `endpoints.unified` | Endpoints group |
| `structure.interface_signatures` | `endpoints.interfaces` | Endpoints group |
| `structure.request_defaults` | `endpoints.request.defaults` | Endpoints group, nested under `request` |
| `structure.pagination` | `endpoints.pagination` | Endpoints group |
| `structure.class_info` | `raw.class_info` | Raw fallback |
| `structure.methods` | `raw.method_inventory` | Raw fallback (renamed for clarity) |
| `structure.overrides` | `raw.overrides_meta` | Raw fallback (override analysis metadata) |
| (new) | `endpoints.raw` | Implicit endpoints surfaced from `describe.api` directly |
| (new) | `endpoints.descriptors` | Task 121 — TS sig + JSDoc per unified method |
| (new) | `endpoints.request.shape` | Tasks 70/71/72 — verb + path template + body encoding |
| (new) | `errors.status_map` | Task 85 — HTTP status → error class |
| (new) | `errors.retry_classification` | Task 86 |
| (new) | `errors.class_hierarchy` | Task 87 |
| (new) | `errors.dispatch` | Tasks 88a/b/c — handler routing tables |
| (new) | `rate_limits.buckets` | Task 89 |
| (new) | `rate_limits.per_endpoint_cost` | Task 90 |
| (new) | `rate_limits.endpoint_cost_binding` | Task 90 — `{bucket_index, axes}` ties per-endpoint costs to `rate_limits.buckets.buckets[bucket_index]` |
| (new) | `normalization.parse_methods_digest` | Task 129 — compact signature digest, **no AST body** |
| (new) | `normalization.field_maps` | Phase 12 Tasks 74–82 — derived per-parser-type field maps |
| (new) | `normalization.response_envelopes` | Task 83 |
| (new) | `markets.currencies` | Task 97 (if shipped by cut) |
| (new) | `markets.precision_mode` | Task 98 (if shipped by cut) |

### Why `normalization.parse_methods_digest` is compact, not raw

`structure.parse_methods` was dropped at v3.0.0 (Task 117) precisely because the raw ESTree bodies blew the Hex 128 MB publish cap that ccxt_client downstream needed cleared. The v4 carrier (Task 129) re-introduces the surface as a **compact digest** — method name → `{params, return_type, async, statement_count}` — preserving the discoverability without re-blowing the cap. The full AST bodies remain in `priv/discoveries/parse_methods.json` for internal Phase 12 derivation; consumers that need them call the extractor's discovery file directly rather than reading them per-exchange.

### `normalization.field_maps.ohlcv` — shape (Task 78, pure-array scope)

Populated for exchanges whose `parseOHLCV` body is a single `ReturnStatement` with an `ArrayExpression` of safe-call elements. `null` for exchanges that inherit `parseOHLCV` from a base class (no override); a populated record with `branches: []` and a non-nil `_unresolved_reason` for exchanges whose override exists but doesn't match a recognized shape (e.g. multiple distinct return arrays).

```json
{
  "branches": [
    {
      "guard":  { "kind": "always" },
      "shape":  "array",
      "field_map": {
        "timestamp": { "index": 0, "key": null, "coercion": "safeInteger2", "format": "ms" },
        "open":      { "index": 1, "key": null, "coercion": "safeNumber2",  "format": null },
        "high":      { "index": 2, "key": null, "coercion": "safeNumber2",  "format": null },
        "low":       { "index": 3, "key": null, "coercion": "safeNumber2",  "format": null },
        "close":     { "index": 4, "key": null, "coercion": "safeNumber2",  "format": null },
        "volume":    {
          "kind": "discriminated",
          "discriminator": "market.inverse",
          "true":  { "index": 7, "coercion": "safeNumber2" },
          "false": { "index": 5, "coercion": "safeNumber2" }
        }
      },
      "_unresolved_reason": null
    }
  ],
  "extras": [],
  "_unresolved_reason": null
}
```

**`coercion` and `discriminator` are closed-vocabulary exceptions to the file-wide open-enum rule (top of this doc).** Unlike `has` capabilities or AST `type` values, these two enums are exhaustive within their scope: consumers MUST hard-error on unrecognized values rather than fall through to a permissive default. The producer never emits an out-of-vocab value; encountering one is a contract violation, not a forward-compat bump. Vocabulary expansion is signalled by a schema major-version bump (e.g. Task 78d/78e/78f), at which point consumers update their match exhaustiveness in lockstep.

**Closed `coercion` vocabulary (initial Task 78 scope):** `["safeInteger", "safeInteger2", "safeNumber", "safeNumber2"]`. A `safeXxx` family member outside this set in any slot emits that slot as `null` with a per-branch `_unresolved_reason: "<field>:non_safe_coercion:<method>"`. Task 78e (`parse8601`) extended this vocab — see the post-78b/78e vocabulary further below in "object-input shape (Tasks 78b + 78e)". Task 78d (`safeTimestamp`) is the next planned extension. The contract is that consumers should error on unrecognized coercion identifiers rather than silently coercing the wrong way.

**Closed `discriminator` vocabulary (this scope):** `["market.inverse"]`. Recognized AST shapes for the `volumeIndex` test: `market['inverse']` MemberExpression, `(market['inverse'])` ParenthesizedExpression, `this.safeBool(market, 'inverse')` CallExpression, or an `Identifier` bound transitively to one of the above (e.g. binance/bitget's chained `const inverse = this.safeBool(market, 'inverse'); const volumeIndex = inverse ? 7 : 5;`). Anything else — e.g. okx's `(type === 'spot') ? 5 : 6` — emits `volume = null` with branch reason `"volume:non_inverse_discriminator"`. Task 78f generalizes the discriminator vocabulary.

**Slot vs discriminated_slot:** pure slots (`%{"index", "key", "coercion", "format"}`) are scalar columns. Discriminated slots (`%{"kind", "discriminator", "true", "false"}`) emit when the column's index is not a literal — consumers branch on the discriminator (e.g. `if market.inverse`, read `slot["true"]`, else `slot["false"]`). The `extras` list is populated by Task 78d for exchanges that emit non-OHLCV columns (e.g. kraken VWAP at index 5 alongside the standard six fields).

**Honesty contract:** every populated slot is provable from AST. Inheriting exchanges (no `parseOHLCV` override) emit `field_maps["ohlcv"] = null`. Override exists but body shape isn't recognized → populated record with non-nil `_unresolved_reason`. Slot-level unresolvability emits `nil` for that slot plus a per-branch reason; other slots in the same branch populate normally.

### `normalization.field_maps.ohlcv` — object-input shape (Tasks 78b + 78e)

Exchanges whose `parseOHLCV` body accesses `ohlcv` by string key (not integer index) emit `input_shape: "object"` on the branch guard, and each slot has `"index": null` with a non-null `"key"`. The branch's existing top-level `"shape": "array"` is unchanged — `shape` describes the parser's *return* value (always an array of `[ts, o, h, l, c, v]`), `input_shape` describes the parser's *raw input* shape; the two are independent. The `coercion` vocabulary gains `"parse8601"` (Task 78e) for exchanges that wrap the timestamp in `parse8601(safeString(ohlcv, key))`.

**Object-input example (hyperliquid / lighter — fully resolved):**

```json
{
  "branches": [
    {
      "guard": { "kind": "always", "input_shape": "object" },
      "shape": "array",
      "field_map": {
        "timestamp": { "index": null, "key": "t", "coercion": "safeInteger",  "format": "ms"   },
        "open":      { "index": null, "key": "o", "coercion": "safeNumber",   "format": null   },
        "high":      { "index": null, "key": "h", "coercion": "safeNumber",   "format": null   },
        "low":       { "index": null, "key": "l", "coercion": "safeNumber",   "format": null   },
        "close":     { "index": null, "key": "c", "coercion": "safeNumber",   "format": null   },
        "volume":    { "index": null, "key": "v", "coercion": "safeNumber",   "format": null   }
      },
      "_unresolved_reason": null
    }
  ],
  "extras": [],
  "_unresolved_reason": null
}
```

**parse8601 timestamp example (bitmex — timestamp slot only):**

```json
{
  "timestamp": { "index": null, "key": "timestamp", "coercion": "parse8601", "format": "iso8601" }
}
```

`"coercion": "parse8601"` means the raw value is an ISO-8601 string that must be parsed to a millisecond epoch integer. Consumers should apply their own `parse8601` / `DateTime.from_iso8601` equivalent. `"format": "iso8601"` is the companion annotation that communicates the wire format of the *raw* value before coercion, paralleling `"format": "ms"` on integer-millisecond columns.

**Closed `coercion` vocabulary (extended by Tasks 78b + 78e):** `["safeInteger", "safeInteger2", "safeNumber", "safeNumber2", "parse8601"]`. The addition of `"parse8601"` is signalled by Task 78e; consumers must add an exhaustive match arm for it before consuming bitmex's timestamp slot.

### `normalization.field_maps.ticker` — shape (Task 74)

`field_maps["ticker"]` carries the per-exchange `parseTicker` field map. Unlike OHLCV, parseTicker always reads its input by string key — no integer-index variant exists in the 110-exchange corpus — so the shape is **flat** (no `branches` wrapper).

**Output shape:**

```json
{
  "field_map": {
    "timestamp":     { "key": "closeTime",  "coercion": "safeInteger2", "format": "ms"  },
    "high":          { "key": "highPrice",  "coercion": "safeString2",  "format": null  },
    "symbol":        null,
    "datetime":      null,
    "info":          null,
    "bid":           { "key": "bidPrice",   "coercion": "safeNumber",   "format": null  },
    "..."
  },
  "extras": [
    { "unified_key": "openInterest", "key": "oi", "coercion": "safeString" }
  ],
  "_unresolved_reason": null
}
```

**Slot shape:** `%{"key" => string, "coercion" => method, "format" => "ms" | "s" | null}`. No `"index"` field — tickers are always key-based.

**22 unified ticker fields in `field_map`** (always present as keys, value `null` when absent or outside closed vocab):
`symbol`, `timestamp`, `datetime`, `high`, `low`, `bid`, `bidVolume`, `ask`, `askVolume`, `vwap`, `open`, `close`, `last`, `previousClose`, `change`, `percentage`, `average`, `baseVolume`, `quoteVolume`, `markPrice`, `indexPrice`, `info`

**Three structurally-null fields by design (always `null`):**
- `symbol` — uses `safeSymbol(ticker, key, market)`, a three-arg call where the second arg is a fallback, not a raw wire key; outside the closed coercion vocabulary
- `datetime` — derived from `timestamp` via `this.iso8601(timestamp)`, not from raw; the `iso8601` call doesn't match the `this.method(obj, key)` pattern and emits `null`
- `info` — the raw ticker object pass-through (bare `ticker` identifier, no safe-call wrapping); emits `null`

**Closed `coercion` vocabulary:** `["safeString", "safeString2", "safeStringN", "safeNumber", "safeNumber2", "safeInteger", "safeInteger2", "safeTimestamp"]`. Any coercion outside this set emits `null` for that slot (honest null).

**Closed `format` vocabulary:** `["ms", "s", null]`. Only meaningful for the `timestamp` field:
- `"ms"` — raw value is a millisecond epoch integer (`safeInteger` / `safeInteger2`)
- `"s"` — raw value is a second epoch integer; multiply by 1000 before storing (`safeTimestamp`)
- `null` — no time-unit annotation (all non-timestamp fields always emit `null`)

**`extras` list:** properties in the `safeTicker(objectExpr, market)` call that are not among the 22 unified fields. Each entry is `%{"unified_key" => key, "key" => wire_key, "coercion" => method}`. An extras slot only appears when its coercion is in the closed vocabulary; non-vocab coercions are silently excluded (same honesty rule as unified slots).

**`_unresolved_reason`:** `null` when the `safeTicker` return pattern was found (even if many individual slots are `null`); a non-null string when the return structure isn't the slottable pattern — e.g. kucoin: `"non_safe_ticker_return:parseContractTicker"`. Inheriting exchanges (no `parseTicker` override) emit `field_maps["ticker"] = null`.

**Honesty contract:** every populated slot is provable from AST. No field is synthesized or inferred from exchange documentation. The same open-closed distinction as OHLCV: `_unresolved_reason` follows one of two patterns — the fixed string `"no_return_statement"`, or the prefix `"non_safe_ticker_return:"` followed by the callee identifier name from the source (open suffix — consumers must match on the prefix, not the full string); `coercion` is closed (hard-error on unrecognized), `format` is closed (hard-error on unrecognized), `key` is open (any wire-format string from the exchange).

### `normalization.field_maps.trade` — shape (Task 76)

`field_maps["trade"]` carries the per-exchange `parseTrade` field map. Same flat shape as ticker (no `branches` wrapper), with three Trade-specific extensions: `enum_map` slot for enum fields, `sub_field_map` slot for nested `fee`, and shape-discriminator detection for multi-payload bodies.

**Output shape:**

```json
{
  "field_map": {
    "id":            { "key": "tradeId", "coercion": "safeString",       "format": null },
    "timestamp":     { "key": "ts",      "coercion": "safeInteger",      "format": "ms" },
    "datetime":      null,
    "symbol":        null,
    "order":         { "key": "ordId",   "coercion": "safeString",       "format": null },
    "type":          null,
    "side":          { "key": "side",    "coercion": "safeStringLower",  "format": null, "enum_map": null },
    "takerOrMaker":  { "key": "execType","coercion": "safeString",       "format": null, "enum_map": {"T": "taker", "M": "maker"} },
    "price":         { "key": "fillPx",  "coercion": "safeString2",      "format": null },
    "amount":        { "key": "fillSz",  "coercion": "safeString2",      "format": null },
    "cost":          null,
    "fee":           { "sub_field_map": { "cost": {...}, "currency": {...} } },
    "info":          null
  },
  "extras": [],
  "_unresolved_reason": null
}
```

**Slot shape:** scalar fields use `%{"key", "coercion", "format"}` (same as ticker). Enum fields (`type`, `side`, `takerOrMaker`) extend with `"enum_map"`. The nested `fee` field uses `%{"sub_field_map" => %{"cost" => slot, "currency" => slot, "rate" => slot}}` instead of scalar key/coercion (`rate` may be nil when the fee object literal omits it). Per-slot unresolved cases (boolean ternary on side, non-ObjectExpression fee, etc.) add `"unresolved_reason"`.

**13 unified Trade fields in `field_map`** (always present as keys, value `null` when absent or outside closed vocab):
`id`, `timestamp`, `datetime`, `symbol`, `order`, `type`, `side`, `takerOrMaker`, `price`, `amount`, `cost`, `fee`, `info`

**Three structurally-null fields by design (always `null`):**
- `symbol` — derived from the `market` argument, not the raw trade object
- `datetime` — derived from `timestamp` via `this.iso8601(timestamp)`, not raw
- `info` — raw trade object pass-through

`cost` is a scalar field but typically null in the current corpus because CCXT computes `price × amount` downstream when the parseTrade body omits it. When an exchange supplies an explicit `cost: this.safeNumber(...)` property, the slot populates.

**Enum fields (`type`, `side`, `takerOrMaker`) — `enum_map` slot:**
- `safeStringLower` extraction → `enum_map: null` (passthrough — CCXT canonicalizes inside the safe call)
- Explicit `safeString().toLowerCase()` chain → `enum_map: null` (canonicalized via chain)
- ConditionalExpression chain over a shared safe-call (`safeString === 'T' ? 'taker' : (safeString === 'M' ? 'maker' : undefined)`) → `enum_map: %{"T" => "taker", "M" => "maker"}` mapping literal wire values to canonical-form arms
- Boolean/numeric/char-code ternary (`x > 0 ? 'buy' : 'sell'`) → slot populated with `enum_map: null` + per-slot `unresolved_reason` describing the test shape

**Nested `fee` field — `sub_field_map` slot:** resolves ObjectExpression literals returned at the `fee` property:
- Inline `{ cost: this.safeNumber(t, 'feeAmt'), currency: this.safeCurrencyCode(this.safeString(t, 'feeCcy')), rate: this.safeNumber(t, 'feeRate') }` → `sub_field_map: %{"cost" => scalar_slot, "currency" => currency_slot, "rate" => scalar_slot}`. `rate` is optional and may be nil when the fee literal omits it.
- `safeCurrencyCode` is a 1-arg vocab member; when bound to an Identifier (`const feeCurrencyId = this.safeString(trade, 'feeCcy')`), `currency` slot traces the binding chain to the underlying safe call's wire key
- Non-ObjectExpression fees (variable reference, externally-built object) → `%{"sub_field_map" => null, "unresolved_reason" => "fee_not_object_literal"}`

**Closed `coercion` vocabulary:** `["safeString", "safeString2", "safeStringN", "safeStringLower", "safeNumber", "safeNumber2", "safeInteger", "safeInteger2", "safeTimestamp", "safeCurrencyCode"]`. Extends the ticker vocab with `safeStringLower` (enum canonicalizer) and `safeCurrencyCode` (1-arg currency resolver, fee-only).

**Closed `format` vocabulary:** `["ms", "s", null]` (same as ticker — only timestamp uses it).

**`_unresolved_reason` — multi-payload detection:** parseTrade bodies that dispatch on shape at the top-level IfStatement emit a single honest unresolved tag instead of committing to one shape. Discriminator tests detected:
- `Array.isArray(trade)` — array-vs-object payload split
- `'<lit>' in trade` — presence-of-key dispatch (binance's `parseDustTrade` delegation)
- `typeof trade === 'string'` — string-vs-object payload split

`_unresolved_reason: "multi_payload_branching:<N>"` where N is the count of distinct shape-discriminator IfStatements. Open suffix — consumers match on the `multi_payload_branching:` prefix, not the full string. `null` when a single canonical `safeTrade` return is found. Inheriting exchanges (no `parseTrade` override) emit `field_maps["trade"] = null`.

**Honesty contract:** every populated slot is provable from AST. No field is synthesized. Same open-closed distinction as ticker: `_unresolved_reason` is open-suffix (`multi_payload_branching:<N>`, `non_safe_trade_return:<callee>`) or one of the closed-set strings (`no_return_statement` — body has no `ReturnStatement` at all; `unrecognized_return_shape` — body has a return whose argument is neither a `this.safeTrade*` call nor a `this.<other>` call); `coercion` is closed; `format` is closed; `key` and `enum_map` arm values are open (from source).

### `normalization.field_maps.transaction` — shape (Task 81)

`field_maps["transaction"]` carries the per-exchange `parseTransaction` field map. Same flat shape as ticker (no `branches` wrapper). TSAsExpression-wrapped returns are unwrapped before classification.

**18 unified Transaction fields in `field_map`** (always present as keys, value `null` when absent or outside closed vocab):
`id`, `timestamp`, `datetime`, `txid`, `type`, `status`, `amount`, `currency`, `address`, `addressFrom`, `addressTo`, `tag`, `tagFrom`, `tagTo`, `network`, `updated`, `fee`, `info`

**Five structurally-null fields by design (always `null`):**
- `info` — raw pass-through identifier, not a safe-call
- `datetime` — derived from `timestamp` via `iso8601`, not raw
- `currency` — resolved via `safeCurrencyCode` 1-arg form, not the 2-arg dict-lookup the classifier recognizes
- `network` — typically resolved via resolver calls (`networkIdToCode`, `getNetworkCodeByNetworkUrl`) outside the closed vocab
- `fee` — built as an inline sub-object `{cost, currency, rate}`, not a flat safe-call on the top-level transaction dict

**Enum fields (`type`, `status`) — `enum_values` slot:**
- `type` → `["deposit", "withdrawal"]`
- `status` → `["ok", "pending", "canceled", "failed"]`

`enum_values` is added to the slot map when the wire key resolves to a safe-call in the closed vocab. Missing or unresolvable wire keys emit `null` for the entire slot.

**Slot shape:** `%{"key" => string, "coercion" => method, "format" => "ms" | "s" | null}`. Timestamp-family fields (`timestamp`, `updated`) carry format: `safeInteger`/`safeInteger2` → `"ms"`, `safeTimestamp` → `"s"`. Enum-family fields extend with `"enum_values" => [string]`.

**`_unresolved_reason`:** `null` when an ObjectExpression return was found (per-field slots may still be `null`). `"no_return_statement"` when no `ReturnStatement` is present. `"non_object_return:<type>"` when the last return yields something other than an ObjectExpression.

**Honesty contract:** same as ticker/trade. Inheriting exchanges (no `parseTransaction` override) emit `field_maps["transaction"] = null`.

### `normalization.field_maps.deposit_address` — shape (Task 82)

`field_maps["deposit_address"]` carries the per-exchange `parseDepositAddress` field map. Flat shape, same classification pipeline as transaction.

**5 unified DepositAddress fields in `field_map`** (always present as keys, value `null` when absent or outside closed vocab):
`currency`, `address`, `tag`, `network`, `info`

**One structurally-null field by design:**
- `info` — raw pass-through, not a safe-call

`network` is nil when the exchange uses a resolver call outside the closed `safe*` vocab (e.g. `getNetworkCodeByNetworkUrl`); populates when `safeString` is used directly.

**Slot shape:** `%{"key" => string, "coercion" => method, "format" => null}` — no timestamp fields, so `format` is always `null`.

**`_unresolved_reason`:** same vocabulary as transaction.

**Honesty contract:** same as ticker/trade/transaction. Inheriting exchanges (no `parseDepositAddress` override) emit `field_maps["deposit_address"] = null`.

### `normalization.field_maps.balance` — shape (Task 77)

`field_maps["balance"]` carries the per-exchange `parseBalance` field map. Imperative pattern: balance bodies assign to `account['free'|'used'|'total'|'debt']` inside loop bodies rather than returning an ObjectExpression, so derivation scans statement-level assignments instead of ObjectExpression properties.

**7 unified Balance fields in `field_map`** (always present as keys, value `null` when absent or outside closed vocab):
`info`, `timestamp`, `datetime`, `free`, `used`, `total`, `debt`

**Structurally-null fields by design (always `null`):**
- `info` — raw balance object pass-through
- `datetime` — derived from `timestamp` via `iso8601`, not raw

**Slot shape:** same as ticker — `%{"key", "coercion", "format"}`. `debt` is rarely populated. `extras` is always `[]` (imperative assignment bodies have no ObjectExpression to scan for extras).

**Closed `coercion` vocabulary:** `["safeString", "safeString2", "safeStringN", "safeNumber", "safeNumber2", "safeInteger", "safeInteger2", "safeTimestamp"]`.

**`_unresolved_reason`:** `null` when `safeBalance(Identifier)` pattern found; `"non_safe_balance_return:<callee>"` when the return is a different `this.<callee>(...)` call; `"no_return_statement"` when no `ReturnStatement` is found; `"identifier_return"` when the return is a bare Identifier (pre-built balance map, e.g. lbank's `return result`); `"unrecognized_return_shape"` when the return argument matches none of the above (e.g. `return foo() + bar()`). Inheriting exchanges (no `parseBalance` override) emit `field_maps["balance"] = null`.

### `normalization.field_maps.market` — shape (Task 79)

`field_maps["market"]` carries the per-exchange `parseMarket` field map. Two slottable return forms: `this.safeMarketStructure({...})` (22 corpus exchanges) and direct `{...}` ObjectExpression (21 corpus exchanges). Non-ObjectExpression returns (e.g. `extend(...)`, bare Identifier) are marked unresolved.

**32 unified Market fields in `field_map`:**
`id`, `symbol`, `base`, `quote`, `settle`, `baseId`, `quoteId`, `settleId`, `type`, `subType`, `spot`, `margin`, `swap`, `future`, `option`, `active`, `contract`, `linear`, `inverse`, `tierBased`, `percentage`, `contractSize`, `expiry`, `expiryDatetime`, `strike`, `optionType`, `taker`, `maker`, `precision`, `limits`, `info`, `created`

**Structurally-null fields by design (always `null`):**
- `symbol` — computed from base/quote/settle, not a direct safe-call
- `info` — raw market object pass-through
- `precision` — nested ObjectExpression (deferred)
- `limits` — deeply-nested ObjectExpression (deferred)
- `expiryDatetime` — derived from `expiry` via `iso8601`

**Closed `coercion` vocabulary:** adds `safeBool` to the standard set for boolean market-type flags (`spot`, `swap`, `future`, `linear`, `inverse`, `option`, `contract`, `active`, `margin`, `tierBased`, `percentage`).

**`extras` list:** ObjectExpression properties beyond the 32 unified fields that resolve to a literal wire key in the closed vocab.

**`_unresolved_reason`:** `null` when ObjectExpression pattern found; `"non_safe_market_return:<callee>"` for non-ObjectExpression `this.<callee>(...)` returns; `"no_return_statement"` when none found; `"identifier_return"` when the return is a bare Identifier (pre-built variable); `"unrecognized_return_shape"` when the return argument matches none of the above (e.g. `return foo() + bar()`). `TSAsExpression` wrappers (`return {...} as Market`) are unwrapped before classification, so a TS-cast around an otherwise-slottable ObjectExpression resolves cleanly (e.g. grvt). Inheriting exchanges emit `field_maps["market"] = null`.

### `normalization.response_envelopes` — shape (Task 83b)

`response_envelopes` carries per-parser-type, per-fetcher maps describing the outer wrapping a vendor REST endpoint returns before the matching `parse*` is dispatched. Recognizes the load-bearing N:1 fetcher→parser pattern: the same parser is reached from multiple fetchers, each with a different envelope (e.g. binance's `parseTrades` is reached from `fetchTrades`, `fetchMyTrades`, `fetchMyDustTrades`).

**Top-level shape** (one key per parser type, plus the closed-vocab `_unresolved_reason` slot):

```json
"response_envelopes": {
  "_unresolved_reason": null,
  "trade": {
    "fetchTrades":       { "key": null,                 "fallback_keys": [], "default": null },
    "fetchMyTrades":     { "key": null,                 "fallback_keys": [], "default": null },
    "fetchMyDustTrades": { "key": "userAssetDribblets", "fallback_keys": [], "default": []   }
  },
  "ticker":          { "fetchTicker": { "key": null, "fallback_keys": [], "default": null }, ... },
  "ohlcv":           { ... },
  "order":           { ... },
  "position":        { ... },
  "balance":         { ... },
  "market":          { ... },
  "transaction":     { ... },
  "deposit_address": { ... }
}
```

**Per-fetcher entry shape (populated):**

| Key | Type | Meaning |
|-----|------|---------|
| `key` | `string \| null` | First arg literal to `this.safeValue(response, "<KEY>", default)` / `this.safeList(response, ...)`. `null` when the response IS the list/object (no unwrap). |
| `fallback_keys` | `string[]` | Additional literal keys from `safeValue2(response, "K1", "K2", default)` / `safeValueN(response, ["K1", "K2"], default)`. Always present as a list (may be empty). |
| `default` | `term \| null` | Literal third arg (number, string, list literal, object literal, or `null` when omitted). |

**Per-fetcher entry shape (unresolved):**

```json
{ "_unresolved_reason": "<closed-vocab-string>" }
```

Carries the `_unresolved_reason` key INSTEAD of the `{key, fallback_keys, default}` triple. Consumers should branch on `Map.has_key?(entry, "_unresolved_reason")`.

**Per-fetcher `_unresolved_reason` vocabulary** (closed):

- `"no_fetcher_method_body"` — `fetch_methods.json` has no body entry for this fetcher
- `"no_safe_value_call"` — fetcher body has no `safeValue` / `safeList` / `safeValueN` / `safeListN` call against `response`
- `"non_literal_key"` — first key arg is a variable rather than a string literal (cannot statically derive)
- `"nested_response_unwrap"` — first arg is a sub-property access (e.g. `response["foo"]["bar"]`); recorded at fetcher level for now

**Top-level `_unresolved_reason`:** `null` when at least one parser-type slot resolved to a populated per-fetcher map; carries `"not_yet_derived"` when the carrier returned the stub (no `parse_dispatch` data, no fetch_methods entry, or the exchange has no override); carries `"no_fetcher_dispatch"` when `parse_dispatch` has entries but none are fetcher names (only mutators like `createOrder` / `transfer` / `describe`), so every parser-type slot is `null`.

**Fetcher scope filter.** Only names beginning with `fetch` are considered — mutators like `createOrder` / `cancelOrder` / `editSpotOrder` are excluded even when they share a parser callee. The per-parser-type fetcher list is the intersection of `parse_dispatch` callers and the parser-type's `parse_fn` set, restricted to `fetch*` names.

**Inheriting exchanges** (no `parse_dispatch` entry, no fetcher bodies) emit `response_envelopes` with every parser-type slot `null` plus `_unresolved_reason: "not_yet_derived"`.

### What changed from 3.x (breaking)

The v4 cut reorganizes all top-level sections from producer-shaped (`runtime` / `structure`) to consumer-shaped groups (`endpoints` / `auth` / `errors` / `rate_limits` / `normalization` / `markets` / `testnet` / `raw`). The full path-migration table is above under "Top-level reshape." Every path that existed under `runtime.*` or `structure.*` has an exact v4 equivalent — no fields were dropped at the cut; the shape is reorganized, not reduced. New sections (`normalization.field_maps`, `endpoints.descriptors`, `errors.class_hierarchy`, `rate_limits.buckets`, etc.) are populated as Phase 12/13/14 tasks ship; their stubs are present and schema-valid from the cut date.

### Migration Notes

Three steps every consumer needs to migrate from v3 to v4:

1. **Bump the major-version pin** — update any `schema_version` check from major `3` to major `4` (see Consumer Guidance code samples above).
2. **Update top-level key reads** — use the "Top-level reshape" table above to map every `runtime.*` / `structure.*` path to its v4 equivalent (e.g., `runtime.symbols_index` → `markets.symbols_index`, `structure.sign_recipe` → `auth.sign_recipe`, `structure.handle_errors` → `errors.handle_errors`).
3. **Point JSON-Schema integration at `exchange_v4.json`** — replace any reference to `exchange_v3.json` with `exchange_v4.json`.

### Legacy v3 fallback

v3 output is available via `--schema-target=3` on `mix ccxt_extract.pipeline` and `mix ccxt_extract.update`. It is removed in Task 143.

---

## Version 3.0.0 — Superseded

**Status:** Superseded by 3.1.0 (released 2026-04-20, Task 117)

**JSON Schema:** `exchange_v3.json` (included in every output directory)

**Summary:** Breaking prune of three dead-weight fields that accounted for
~85% of every large exchange's emitted JSON (binance `runtime.markets`
was 23.6 MB on its own). The replacement for `runtime.markets` is the
compact derived `runtime.symbols_index`. `structure.parse_methods` and
`structure.ws_methods` are dropped outright — consumers never read them
in production, and the extractors still populate `priv/discoveries/*.json`
for internal Phase 12 / Phase 15 derivation consumers.

### What changed from 2.x (breaking)

- **`runtime.markets` is gone.** Replaced by `runtime.symbols_index` — a
  compact map `%{symbol => {spot: bool, swap: bool}}` keyed by CCXT
  unified symbol (e.g. `"BTC/USDT"`, `"BTC/USDT:USDT"`). For `market_count`,
  take the map size of `symbols_index`. For `price`, `precision`, `fees`,
  `limits`, `info`, `baseId`, or `quoteId`, call the exchange's real
  `loadMarkets()` at runtime — the old snapshot was stale anyway.
- **`structure.parse_methods` is gone.** The extractor still runs and
  emits `priv/discoveries/parse_methods.json` for internal consumers, but
  the AST dump is no longer shipped in per-exchange output.
- **`structure.ws_methods` is gone.** Same — `priv/discoveries/ws_methods.json`
  retained internally, not emitted in per-exchange output.
- **JSON Schema file renamed** `exchange_v2.json` → `exchange_v3.json`.
  The retained-for-diff `priv/schema/exchange_v2.json` was deleted
  2026-05-07 (Task 118) once the one-release grace window expired.
- **Consumer major-version pin** moves from `2` → `3`. Update your version
  check (see Migration Notes below).
- **Provenance map** loses `/runtime/markets`, `/structure/parse_methods`,
  `/structure/ws_methods` (all were `raw`); gains `/runtime/symbols_index`
  (tagged `derived`). `provenance_covers_schema` contract-test invariant
  auto-rebaselines off `CcxtExtract.Provenance.{raw_pointers,derived_pointers}/0`.

### Migration Notes

```python
# Python — version check + derivations
data = json.load(f)
major = int(data["schema_version"].split(".")[0])
if major != 3:
    raise ValueError(f"Unsupported schema version: {data['schema_version']}")

# runtime.markets is gone. Use runtime.symbols_index:
symbols_index = data["runtime"]["symbols_index"]  # {symbol: {spot, swap}}
market_count = len(symbols_index)                  # was data["runtime"]["markets"]["market_count"]
symbols = list(symbols_index.keys())               # was data["runtime"]["markets"]["markets"].keys()
spot_symbols = [s for s, m in symbols_index.items() if m["spot"]]
swap_symbols = [s for s, m in symbols_index.items() if m["swap"]]

# For price / precision / fees / limits / info / baseId / quoteId — these were
# only ever a snapshot that drifts between extraction runs. Call the exchange's
# real loadMarkets() at runtime.
```

```rust
// Rust
let symbols_index = data["runtime"]["symbols_index"].as_object().unwrap();
let market_count = symbols_index.len();
let spot_symbols: Vec<&String> = symbols_index
    .iter()
    .filter(|(_, m)| m["spot"].as_bool().unwrap_or(false))
    .map(|(s, _)| s)
    .collect();
```

```elixir
# Elixir
case data do
  %{"schema_version" => "3." <> _, "runtime" => %{"symbols_index" => idx}}
      when is_map(idx) ->
    market_count = map_size(idx)
    spot_symbols = for {s, %{"spot" => true}} <- idx, do: s
    {:ok, market_count, spot_symbols}

  %{"schema_version" => v} ->
    {:error, {:unsupported_schema_version, v}}
end
```

Consumers that pointed at `exchange_v2.json` for schema introspection should
point at `exchange_v3.json` in their build steps.

### Fields Removed

Every removed key path and its recommended migration:

| Removed path | Migration |
|--------------|-----------|
| `runtime.markets` | Use `runtime.symbols_index` (see above) |
| `runtime.markets.market_count` | `map_size(symbols_index)` / `len()` / `.len()` |
| `runtime.markets.markets` | `Map.keys(symbols_index)` for the symbol list; call real `loadMarkets()` for per-market metadata |
| `structure.parse_methods` | Was an internal AST dump; not intended for consumers. If you were using it, reconsider — it's discovery-file data now |
| `structure.ws_methods` | Same as above |

### Why

Cross-repo grep at Task 117 filing confirmed zero live readers of
`runtime.markets.markets` beyond per-symbol `spot`/`swap` boolean
classification, and zero live readers of `structure.parse_methods` /
`structure.ws_methods` in any downstream consumer (`ccxt_client` and
others). The three fields together accounted for ~85% of every large
exchange's emitted JSON. Dropping them clears the Hex 128 MB publish cap
for downstream packages with ≥30 % headroom.

The previous `## Version 2.x` baseline documentation follows; subsequent
minor bumps (2.1.0 request_defaults, 2.2.0 sign_recipe scaffold, 2.3.0
per-verb canonical_string, 2.4.0 testnet_urls) shipped under the 2.x
line and are preserved here for historical reference.

---

## Version 2.4.0 — Superseded

**Status:** Superseded by 3.0.0 (released 2026-04-20, Task 117)

**JSON Schema:** `exchange_v2.json` (deleted 2026-05-07 — Task 118; see [Version History](#version-history))

**Latest change:** Adds `runtime.testnet_urls` — a required, structured
testnet / sandbox URL catalog derived from `describe.urls.test` and
`describe.options.sandboxMode`. See **Testnet URL Catalog** below.

The previous `## Version 2.0.0` baseline documentation follows; subsequent
minor bumps (2.1.0 request_defaults, 2.2.0 sign_recipe scaffold, 2.3.0
per-verb canonical_string, 2.4.0 testnet_urls) are additive — consumers
pinned to major version `2` continue to read without change aside from
the new required-field shapes.

## Version 2.0.0 — Baseline

**Status:** Superseded by 2.4.0 (but consumer major-version contract is still `2`)

**JSON Schema:** `exchange_v2.json` (included in every output directory)

### What changed from 1.8.1 (breaking)

- **`_provenance` is now required and non-null** on every emitted exchange
  JSON. Previously optional/nullable (1.8.1 additive). The field describes
  per-path source tiers (`raw` / `derived` / `override`) and is populated
  unconditionally by `CcxtExtract.Schema.build_exchange/4`.
- **JSON Schema file renamed** `exchange_v1.json` → `exchange_v2.json`.
  `priv/schema/exchange_v1.json` is retained for ONE release so maintainers
  can diff the two; it is **not** copied into the output directory. The
  next schema release will delete the v1 file.
- **Consumer major-version pin** moves from `1` → `2`. Update your version
  check (see Migration Notes below).

No field semantics changed, no fields were removed or renamed. If you adopted
`_provenance` during the 1.8.1 window, your reader code works unchanged at
2.0.0.

### Migration Notes

Update the version-check snippet your consumer uses on load:

```python
# Python
data = json.load(f)
major = int(data["schema_version"].split(".")[0])
if major != 2:
    raise ValueError(f"Unsupported schema version: {data['schema_version']}")
# _provenance is now guaranteed present and non-null:
provenance = data["_provenance"]  # type: dict[str, Literal["raw","derived","override"]]
```

```rust
// Rust
let major: u32 = data["schema_version"].split('.').next().unwrap().parse()?;
assert_eq!(major, 2, "Unsupported schema version");
// _provenance is guaranteed object-typed, not null.
let provenance = data["_provenance"].as_object().expect("_provenance is required in 2.0.0");
```

```elixir
# Elixir
case data do
  %{"schema_version" => "2." <> _, "_provenance" => provenance}
      when is_map(provenance) -> :ok
  %{"schema_version" => v} -> raise "Unsupported schema version: #{v}"
end
```

Consumers that pointed at `exchange_v1.json` for schema introspection should
point at `exchange_v2.json` in their build steps.

### Top-Level Structure

Every per-exchange JSON file has exactly these top-level keys (**all required**):

| Key | Type | Description |
|-----|------|-------------|
| `schema_version` | `"2.0.0"` | This contract version |
| `extracted_at` | string (ISO 8601) | When extraction ran |
| `ccxt_version` | string | CCXT npm package version used |
| `exchange` | ExchangeMeta | Exchange identity and metadata |
| `runtime` | RuntimeData | QuickBEAM-extracted values |
| `structure` | StructureData | OXC AST-extracted structure |
| `_provenance` | ProvenanceMap | Required non-null per-path source tags (see below) |

### Provenance Map (schema 2.0.0)

The `_provenance` field is a flat map keyed by JSON Pointer strings. Every
value is one of three string tiers:

- `"raw"` — the field at this path is a direct passthrough from a discovery
  file. No transformation happened between the extractor and emission.
- `"derived"` — the field was computed at assembly time by a derivation
  module (`SymbolPatterns.derive/2`, `AuthenticatedSections.derive/2`,
  `ErrorCodeFields.derive/1`, `ThrowDispatches.derive/1`, the
  `get_unified_endpoints/2` pipeline in `Pipeline`). The value is still
  AST-provable; nothing hand-curated reached it.
- `"override"` — the field was replaced by an entry in
  `priv/overrides/<id>.json` at the tail of `Pipeline.extract/1`. The
  override file carries a required `reason` explaining the divergence
  from extraction — consumers who want that context should read the
  override file directly.

Granularity is section + direct children. The map does not recurse to every
leaf; it describes which MODULE produced the field, not each byte. The
exception is `/structure/handle_errors`, whose sub-keys split between raw and
derived and therefore carry per-subkey tags.

**Default entries (when no override applies):**

```json
{
  "_provenance": {
    "/exchange/id": "raw",
    "/exchange/name": "raw",
    "/exchange/certified": "raw",
    "/exchange/pro": "raw",
    "/exchange/version": "raw",
    "/exchange/country": "raw",
    "/exchange/alias": "raw",
    "/exchange/referral": "raw",
    "/exchange/tier": "derived",
    "/runtime/describe": "raw",
    "/runtime/markets": "raw",
    "/runtime/symbol_patterns": "derived",
    "/runtime/testnet_urls": "derived",
    "/runtime/url_templates": "raw",
    "/runtime/request_headers": "raw",
    "/structure/class_info": "raw",
    "/structure/methods": "raw",
    "/structure/sign_method": "raw",
    "/structure/authenticated_sections": "derived",
    "/structure/handle_errors/method": "raw",
    "/structure/handle_errors/exceptions": "raw",
    "/structure/handle_errors/http_exceptions": "raw",
    "/structure/handle_errors/error_code_fields": "derived",
    "/structure/handle_errors/throw_dispatches": "derived",
    "/structure/parse_methods": "raw",
    "/structure/ws_methods": "raw",
    "/structure/interface_signatures": "raw",
    "/structure/pagination": "raw",
    "/structure/overrides": "raw",
    "/structure/unified_endpoints": "derived"
  }
}
```

**Override stamping.** When `priv/overrides/<id>.json` contains
`{"path": "/structure/authenticated_sections", ...}`, the provenance value at
that pointer flips from `"derived"` to `"override"`. Override paths deeper
than default granularity (e.g. `/structure/sign_method/params/timestamp`) get
added as new entries with value `"override"` — the ancestor entry
(`/structure/sign_method`) keeps its `"raw"` tag because the rest of the
sub-tree is still raw.

**Null semantics.** The tier describes where the field WOULD have come from,
not whether it's currently populated. Many fields are `null` for many
exchanges (e.g., `/structure/ws_methods` on rest-only exchanges). Provenance
still records the tier so consumers can distinguish "this is raw null,
discovery had no data" from "this is override null, curator chose to erase
upstream data."

### Two-Layer Model

- **runtime** — what an exchange IS: resolved `describe()` config, `loadMarkets()` data
- **structure** — what an exchange DOES: class hierarchy, method signatures, method AST bodies

### Two-State Optionality

Every data field uses exactly two states:

- **Present** — extraction succeeded; value is a map, list, or object
- **null** — layer is missing, empty, or does not apply to this exchange

All keys are always materialized (never absent). Consumers check for `null`, never for key existence.

### Runtime Layer (`runtime`)

| Field | Type | Description |
|-------|------|-------------|
| `describe` | object or null | Full `describe()` output — api endpoints, `has` capabilities, fees, limits, urls, exceptions, features, timeframes, requiredCredentials |
| `markets` | MarketsData or null | `loadMarkets()` result — symbol formats, precision, limits, fee structures |
| `symbol_patterns` | SymbolPatterns or null | Derived symbol formatting patterns per market type — separator, case, ID structure, suffix, anomalies. Consumers use for unified ↔ exchange-native symbol conversion |
| `request_headers` | RequestHeaders | Always-emit wrapper `{user_agent: string\|null, default_headers: object<string, string>}`. `user_agent` is the resolved per-exchange UA string (or null when CCXT didn't override the base default). `default_headers` is a flat string-to-string map (empty `{}` when no override). Sourced via QuickBEAM constructor instantiation. Coverage is sparse (~8% UA, ~4% headers in the full corpus); most exchanges emit the empty wrapper. **Schema 3.1.0+.** Note: two known QuickBEAM blind spots — `bigone.ts` (sign-time UA construction) and `okx.ts` (`setSandboxMode()` runtime mutation) — are NOT captured here; tracked as Task 73e. |

### Structure Layer (`structure`)

| Field | Type | Description |
|-------|------|-------------|
| `class_info` | ClassInfo or null | Class hierarchy — REST and WS class names, parents, method counts |
| `methods` | MethodInventory or null | Method signature inventory (names, params, return types — no AST bodies) |
| `sign_method` | MethodAST or null | `sign()` method with full ESTree AST body |
| `authenticated_sections` | string[] or null | API sections proven to require authentication via `checkRequiredCredentials()` gates in sign() AST. Handles `api === 'X'` and `api[N] === 'X'` patterns. Sorted. May also contain dotted paths like `"contract.private"` when `describe.api` nests authenticated children under container keys (htx, huobi). Both flat and nested forms coexist in the same list. Null when sign() absent; empty list when sign() exists but no `checkRequiredCredentials()` gates found. Note: some exchanges authenticate without `checkRequiredCredentials()` — use `sign_method` AST for broader auth detection. |
| `sign_recipe` | map(section -> SignRecipeRecord) | Per-section declarative signing recipe. Keys mirror `authenticated_sections` (enforced by the `sign_recipe_keys_match_auth_sections` contract invariant). Empty map `{}` when the exchange has no authenticated sections. Each record is `{crypto_op, canonical_string, signature_placement, auth_headers, nonce, pre_sign_transforms, unresolved_reason, patch_count}` — all derivation fields nullable; populated incrementally by Phase 10 tasks 65–69. Scaffolded in 2.2.0 with every field `null` + `unresolved_reason: "not_yet_derived"`. See [Signing Recipe (2.2.0+)](#signing-recipe-220). |
| `handle_errors` | HandleErrorsData or null | `handleErrors()` AST plus exception mappings |
| `parse_methods` | map(name -> MethodAST) or null | `parse*()` methods with AST bodies |
| `ws_methods` | map(name -> MethodAST) or null | `watch*()` / `handle*()` WS methods with AST bodies |
| `interface_signatures` | map(name -> InterfaceSignature) or null | Typed API method signatures from `abstract/*.ts` |
| `pagination` | map(name -> [PaginationEntry]) or null | Per-method pagination strategy and parameters (always arrays; `_unresolved` key for variable method names) |
| `overrides` | OverridesData or null | Method override analysis for derived exchanges |
| `unified_endpoints` | map(name -> string[]) or null | Unified method → interface method mappings (e.g., `fetchTicker` → `["publicGetV5MarketTickers"]`) |
| `request_defaults` | RequestDefaults or null | Per-method default request body: map of method name → {key → RequestDefaultsEntry}. Literal primitives emit `kind: "literal"` with the value; non-literal expressions emit `kind: "unresolved"` with a closed-vocabulary reason (see RequestDefaultsEntry). Methods with no HTTP call, pure delegation, empty body, or divergent multi-call-site bodies are absent. Null when no method produced extractable defaults. |

### Key Type Definitions

For complete type definitions (all fields, nesting, and constraints), see `exchange_v3.json` — the JSON Schema shipped in every output directory. The summary below covers the most-referenced types:

- **MethodAST** — `{ async, params, return_type, statements, body }` where `body` is a complete ESTree BlockStatement
- **InterfaceSignature** — `{ name, params, return_type }` (no body — these are type declarations, not implementations)
- **MethodParam** — `{ name, type }` where `type` is the TypeScript type annotation or null
- **ASTNode** — ESTree nodes with `type`, `start`, `end` (byte offsets), plus node-specific fields
- **HandleErrorsData** — `{ method, exceptions, http_exceptions, error_code_fields, throw_dispatches }` where `method` is a MethodAST, `exceptions` maps error strings to class names (keyed by `broad`/`exact` plus market types), `http_exceptions` maps HTTP status codes to class names, `error_code_fields` is a list of ErrorCodeFieldEntry, and `throw_dispatches` is a list of ThrowDispatchEntry
- **ErrorCodeFieldEntry** — `{ object, object_path, field, method, field2, roles, sentinel_values }` — a single `this.safe*()` call from handleErrors() with role classification. `object` is the first arg identifier (e.g., `"response"`, `"error"`), `object_path` is the derivation path tracing back to `response` (e.g., `["response", "data", "failure", "0"]`) or null for trivial cases. `field` is the literal field name accessed, `method` is `"safeString"` / `"safeString2"` / `"safeValue"`, `field2` is the alternate field for safeString2. `roles` is an array of `"error_code"` / `"error_message"` / `"status_sentinel"` classified by the CCXT helper: `throwExactlyMatchedException` → `error_code` (exact-map lookup key — not necessarily numeric, e.g., OKX's `sCode` is a string), `throwBroadlyMatchedException` → `error_message` (message text scanned for substrings of `exceptions.broad` keys), `===`/`!==` comparisons → `status_sentinel`. A field hit by both throw helpers in the same handleErrors() accumulates both roles. `sentinel_values` is an array of `{ value, operator }` objects where `operator` is `"==="` or `"!=="` (for polarity detection), sorted by value, or null when no sentinel role.
- **ThrowDispatchEntry** — `{ helper, exceptions_source, exceptions_source_raw, lookup, message_lookup }` — a single `this.throwExactlyMatchedException()` / `this.throwBroadlyMatchedException()` call from handleErrors(). `exceptions_source` normalizes arg[0] to `"exceptions"`, `"exceptions.exact"`, `"exceptions.broad"`, `"by_url.exact"`, `"by_url.broad"`, or `"other"`; `exceptions_source_raw` preserves the original expression as a compact string. `lookup` is the resolved safe* binding for arg[1]. `message_lookup` is the unique resolved safe* binding referenced anywhere inside arg[2] (including aliases like `errorInfo = message` and wrappers like `this.json(message)`), or null when the message expression does not point at a single bound lookup value.
- **PaginationEntry** — `{ strategy, containing_method, target_method, max_entries_per_request, ... }` where `strategy` is one of `"dynamic"`, `"deterministic"`, `"cursor"`, `"incremental"`. `containing_method` is the method body where the call was found; `target_method` is the method name passed to `fetchPaginatedCall*` (null for unresolved variable references). Strategy-specific fields: cursor has `cursor_received`, `cursor_sent`, `cursor_increment`; incremental has `page_key`. Null values mean the parameter was not statically resolvable from source.
- **OverridesData** — `{ extends, rest, ws }` where `extends` is the parent exchange id, and each entry contains `overridden` (methods redefined from parent, with AST), `new_methods` (methods not on parent), and `inherited` (method names only)
- **SignRecipeRecord** — `{ crypto_op, canonical_string, signature_placement, auth_headers, nonce, pre_sign_transforms, unresolved_reason, patch_count }`. All derivation fields are nullable — scaffold defaults every field to `null`. `crypto_op`: `{ algo ∈ "hmac_sha256" | "hmac_sha512" | "hmac_sha384" | "ed25519" | "rsa" | "custom", reason? }`. `canonical_string`: `{ family ∈ "hmac_simple" | "hmac_with_body" | "jwt" | "custom", components: [{ source, value? }], encoding ∈ "url_encoded" | "json" | "raw" }` where `source` ∈ `"timestamp" | "api_key" | "recv_window" | "method" | "path" | "query" | "body" | "literal"`. `signature_placement`: `{ location ∈ "header" | "query" | "body", key }`. `auth_headers`: `[{ name, source ∈ "api_key" | "passphrase" | "timestamp" | "signature" | "recv_window" | "literal", value? }]` — excludes the signature header itself (use `signature_placement` for that). `nonce`: `{ source ∈ "timestamp_ms" | "timestamp_sec" | "timestamp_us" | "timestamp_ns" | "monotonic" | "exchange_supplied", format ∈ "integer" | "iso8601" | "hex" | "string" }`. `pre_sign_transforms`: `[{ op ∈ "hex_encode" | "base64_encode" | "lowercase" | "url_encode" | "json_encode", target ∈ "signature" | "body" | "canonical_string" }]`. `unresolved_reason`: `null` | `"not_yet_derived"` | `"custom_signing_family"` | `"ambiguous_ast"` | `"no_sign_method"` — must be `null` if and only if every derivation field above is non-null (enforced by the `sign_recipe_honesty_valid` contract invariant, shipped Task 69 on 2026-04-24). `patch_count`: non-negative integer, Three-Strikes counter (see CLAUDE.md). Standalone JSON Schema at `priv/schema/sign_recipe_v1.json`.
- **RequestDefaultsEntry** — `{ value, kind, reason }` where `kind` ∈ `"literal" | "unresolved"`. For `literal`: `value` is the resolved primitive (string/number/boolean/null), a map of string keys → primitives (nested literal), or a list of primitives (array of literals); `reason` is null. For `unresolved`: `value` is null; `reason` ∈ `"conditional_value"` (ternary/logical expression), `"identifier_reference"` (variable or member access), `"dynamic_construction"` (call, binary, template literal, partially-literal object/array), `"computed_key"` (key was a computed `[expr]`), `"spread_elaboration"` (reserved for future spread tracking). Keys preserve the exchange's own literal string keys; computed keys surface as the synthetic key `"_computed"`.
- **ClassInfo** — `{ rest, ws }` where each is a ClassEntry with `class_name`, `extends_resolved`, `parent_key`, `file`, `method_count`, and optional `method_details`
- **MethodInventory** — `{ rest, ws }` where each is a list of MethodSignature (like MethodAST but without `body`)
- **ExchangeMeta** — `{ id, name, alias, certified, pro, version, country, referral, tier }` — exchange identity, CCXT metadata, plus `tier` ∈ `"tier1" | "tier2" | "tier3" | "dex" | "unclassified"` (hand-curated in `priv/priority_tiers.json`, not extracted from CCXT; `tier1`/`tier2`/`dex` are the buckets this project commits to deriving recipes for)

### Shared Artifacts

These files are **global** (not per-exchange) and live alongside `_manifest.json` in the output directory:

#### `_base_methods.json`

Base class method signatures from `Exchange.ts` — shared by all exchanges.

| Key | Type | Description |
|-----|------|-------------|
| `extracted_at` | string (ISO 8601) | Extraction timestamp |
| `source_file` | string | Always `"base/Exchange.ts"` |
| `method_count` | integer | Total methods extracted |
| `by_category` | object | Count per category (`parse`, `safe`) |
| `methods` | map(name -> BaseMethod) | Method signatures keyed by name |

**BaseMethod** — `{ name, category, params, return_type, async, source }` where `category` is `"parse"` or `"safe"`, `params` is a list of MethodParam, `async` is boolean, and `source` is `"method_definition"` (full method with signature) or `"field_assignment"` (class field alias to imported utility — no params/return type available).

### Manifest (`_manifest.json`)

| Key | Type | Description |
|-----|------|-------------|
| `schema_version` | string | Same as per-exchange files |
| `ccxt_version` | string | CCXT version used |
| `extracted_at` | string (ISO 8601) | Extraction timestamp |
| `exchange_count` | integer | Number of exchange files |
| `exchanges` | string[] | Sorted list of exchange IDs |
| `tier_scope` | string \| string[] | Active scope stamped on write by `CcxtExtract.Scope.to_manifest_value/1`. `"all"` for unscoped / `--all` runs; otherwise a canonicalized list of scope tokens — tier names in canonical order (`"tier1"`, `"tier2"`, `"tier3"`, `"dex"`) followed by alphabetized `"exchange:<id>"` entries. Examples: `["tier1", "dex"]`, `["exchange:binance", "exchange:deribit"]`, `["tier1", "exchange:hyperliquid"]`. Lets consumers detect partial aggregates produced by scoped extraction runs (`--tier*`, `--exchange ID`). |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 4.0.0 | 2026-05-15 | **Breaking.** Default emitted and validated schema (Task 142). Top-level reshape from producer-shaped (`runtime`/`structure`) to consumer-shaped sections (`endpoints`/`auth`/`errors`/`rate_limits`/`normalization`/`markets`/`testnet`/`raw`). Re-introduces the normalization surface dropped at 3.0.0 (compact `normalization.parse_methods_digest` + Phase 12 derived field maps — **NOT** raw AST bodies, preserving the 3.0.0 Hex-cap reduction). Consumer major-version pin bumps `3` → `4`. v3 remains reachable via `--schema-target=3` as a legacy fallback, removed in Task 143. See [Version 4.0.0 — Current](#version-400--current) for the full path-migration table and migration notes. |
| 3.3.0 | 2026-05-08 | Add required `structure.transaction_classification` — per-unified-endpoint `{transactional, on_chain}` boolean flags derived from CCXT's unified-method naming convention (`fetch*` → read-only; `withdraw*` → on_chain; `transfer` stays off-chain because it's exchange-internal). Mirrored at `endpoints.transaction_classification` in v4 — peer to `endpoints.unified`, not nested. New `TransactionClassificationEntry` `$def`. `_provenance["/structure/transaction_classification"] = "derived"`. **Minor bump** because the key is now in `Structure.required` — strict validators reject 3.2.0 output lacking it. **Security gap** (out of scope, tracked as Task 73f): non-unified raw broadcast endpoints (`signL1Action` / `signEIP712`, `public_post_sendtx`) do not appear in this map; consumers must not treat `on_chain == false` (or absence) as a safety gate. Same release retroactively closes a Task 87 gap in `OverrideRegistry.@v3_to_v4_pointer_prefixes` (added `/structure/error_class_hierarchy` → `/errors/class_hierarchy` translation entry alongside the new `/structure/transaction_classification` → `/endpoints/transaction_classification` mapping). See [Version 3.3.0 — Superseded](#version-330--superseded). |
| 3.2.0 | 2026-05-08 | Add required `structure.error_class_hierarchy` — CCXT's exception class taxonomy (`BaseError → ExchangeError → ... → AccountNotEnabled`) extracted from `priv/ccxt/ts/src/base/errorHierarchy.ts` via OXC. Three projections per record: `tree` (recursive map mirroring source literal), `flat_parents` (`class → parent`, root → `null`, O(1) parent lookup), `ancestors` (`class → [parent, ..., BaseError]`, O(1) ancestor chain). Corpus-global data — every per-exchange JSON carries the same record, matching `error_code_fields` / `throw_dispatches` colocation under `structure`. `_provenance["/structure/error_class_hierarchy"] = "derived"` (`flat_parents` and `ancestors` are pre-computed projections). Two new contract invariants: `error_class_hierarchy_shape_valid` (intrinsic shape + single root + walk agreement, cycle-safe) and `error_classes_covered_by_hierarchy` (every class in `handle_errors.exceptions` / `http_exceptions` exists in `flat_parents`). v4's `errors.class_hierarchy` slot populated alongside `errors.handle_errors`. **Minor bump** because the key is now in `Structure.required` — strict validators reject 3.1.0 output lacking it; permissive readers are unaffected. See [Version 3.2.0 — Superseded](#version-320--superseded). |
| 3.1.0 | 2026-05-07 | Add required `runtime.request_headers` — always-emit `{user_agent: string\|null, default_headers: object<string, string>}` wrapper sourced from CCXT's resolved `describe()` runtime (per-exchange `userAgent` override + default `headers` map). Populated via QuickBEAM constructor instantiation in `CcxtExtract.RequestHeaders`; consumers replace any hardcoded UA / version-header tables with reads from this field. `_provenance["/runtime/request_headers"] = "raw"`. **Minor bump** because the key is now in `RuntimeData.required` — strict validators reject 3.0.0 output lacking it; permissive readers are unaffected. Two known blind spots (sign-time UA construction in `bigone.ts`, runtime `setSandboxMode()` header mutation in `okx.ts`) tracked as Task 73e. See [Version 3.1.0 — Current](#version-310--current). |
| 3.0.0 | 2026-04-20 | **Breaking.** Replace `runtime.markets` with compact derived `runtime.symbols_index` (map of symbol → `{spot: bool, swap: bool}`); drop `structure.parse_methods` and `structure.ws_methods` from emitted output (extractors retained; discovery files still written to `priv/discoveries/` for internal Phase 12 / Phase 15 consumers). Rename JSON Schema file `exchange_v2.json` → `exchange_v3.json`. `priv/schema/exchange_v2.json` retained one release for diff reference. Provenance map drops three raw pointers and gains `/runtime/symbols_index` (derived). Consumer major-version pin bumps `2` → `3`. Clears the ccxt_client Hex 128 MB publish cap (binance pretty-JSON 56.2 MB → compact-JSON + pruned 25.6 MB → ~2 MB). See [Version 3.0.0 — Current](#version-300--current) for migration notes. |
| 2.4.0 | 2026-04-19 | Add nullable-by-pattern `runtime.testnet_urls` and promote it into `RuntimeData.required` — structured testnet / sandbox URL catalog with `pattern` enum (`separate_host` / `sandbox_flag` / `none`), `{hostname}` pre-resolution, and independent `sandbox_flag_field` that tracks `options.sandboxMode` presence. Replaces consumer-side reach-into `runtime.describe.urls.test` (opaque passthrough). New `testnet_urls_shape_valid` contract invariant. `_provenance["/runtime/testnet_urls"] = "derived"`. **Minor bump** because the key is now in `RuntimeData.required` — strict validators reject 2.3.0 output lacking it; permissive readers are unaffected. See [Testnet URL Catalog (2.4.0+)](#testnet-url-catalog-240). |
| 2.3.0 | 2026-04-19 | Reshape `sign_recipe.<section>.canonical_string` from a **single record** to a **per-verb map** keyed on HTTP verb (`GET`/`POST`/`PUT`/`DELETE`/`PATCH`) or the sentinel `*` (uniform across all verbs). A single section can now carry multiple families (e.g. OKX.private: `GET` = hmac_simple for query-signed GETs; a future `POST` entry will be hmac_with_body for body-signed POSTs). Task 66a populates hmac_simple entries; Task 66b will populate hmac_with_body entries in parallel. Practically additive — no consumer previously parsed a populated `canonical_string` (every record landed null at 2.2.0). **Minor bump** because the populated shape is new. First-run coverage: OKX.private.GET populated; all other priority exchanges remain null with truthful `unresolved_reason` tags pending Tasks 66b/66e/66f. |
| 2.2.0 | 2026-04-18 | Add `structure.sign_recipe` as per-section declarative signing recipe — scaffold only. Keys mirror `authenticated_sections`; values are `SignRecipeRecord` with every derivation field (`crypto_op`, `canonical_string`, `signature_placement`, `auth_headers`, `nonce`, `pre_sign_transforms`) `null` and `unresolved_reason: "not_yet_derived"`. Populated incrementally by Phase 10 tasks 65–69. Standalone JSON Schema at `priv/schema/sign_recipe_v1.json` kept in lockstep with `exchange_v2.json#/$defs/SignRecipeRecord`. Two new contract-test invariants: `sign_recipe_keys_match_auth_sections` and `sign_recipe_shape_valid`. Provenance: `/structure/sign_recipe` tagged `"derived"`. **Minor bump** because the key is now in `StructureData.required` — strict validators reject 2.1.0 output lacking it; permissive readers are unaffected. See [Signing Recipe (2.2.0+)](#signing-recipe-220). |
| 2.1.0 | 2026-04-18 | Add nullable `structure.request_defaults` and promote it into `StructureData.required` — per-method default request body as `method → {key → RequestDefaultsEntry}` where each entry is `{value, kind, reason}` with `kind ∈ "literal" | "unresolved"`. Unresolved `reason` enum: `conditional_value`, `identifier_reference`, `dynamic_construction`, `computed_key`, `spread_elaboration`. Populated by `CcxtExtract.RequestDefaults`; consumers use this to POST correct type-discriminated bodies (e.g., hyperliquid's `{"type": "exchangeStatus"}` for fetchTime) without walking AST. `_provenance["/structure/request_defaults"] = "derived"`. **Minor bump** because the key is now in `StructureData.required` — strict validators will reject 2.0.0 output lacking it; permissive readers that ignore unknown keys are unaffected. |
| 2.0.0 | 2026-04-17 | **Breaking.** Promote `_provenance` to required, non-null top-level key. Rename schema file `exchange_v1.json` → `exchange_v2.json`. `priv/schema/exchange_v1.json` retained one release for diff reference, deleted 2026-04-18 (Task 107). Consumer major-version pin bumps `1` → `2`. No field semantics changed; readers that already consumed `_provenance` at 1.8.1 work unchanged. See [Version 2.0.0 — Current](#version-200--current) for migration notes. |
| 1.8.1 | 2026-04 | Add additive, nullable top-level `_provenance` map keyed by RFC 6901 JSON Pointers with values `"raw"` / `"derived"` / `"override"`. Stamped by `CcxtExtract.Provenance.build_default/0` at assembly time; override-applied paths flipped to `"override"` at the tail of `Pipeline.extract/1`. Optional at 1.8.x — consumers reading 1.8.0 still parse 1.8.1 output. Promoted to required at 2.0.0. |
| 1.8.0 | 2026-04 | Add optional `exchange.tier` field (`"tier1" \| "tier2" \| "tier3" \| "dex" \| "unclassified"`). Additive — consumers reading 1.7.1 still parse 1.8.0 output cleanly. Hand-curated in `priv/priority_tiers.json`; stamped by `CcxtExtract.Tiers.get_priority_tier/1` during pipeline assembly. Also adds `tier_scope` to `_manifest.json` (`string` when `"all"`, otherwise `string[]` of canonical tokens — tiers first, then `"exchange:<id>"` entries) recording the active scope of a run; lets consumers detect partial aggregates from scoped extraction. |
| 1.7.1 | 2026-04 | Fix `structure.authenticated_sections` extraction. Field shape unchanged; population fixed to handle nested `api[N] === 'X'` patterns and a narrow override loader. |
| 1.7.0 | 2026-04 | Add `structure.handle_errors.throw_dispatches` — one entry per `this.throwExactly/BroadlyMatchedException` call in the handleErrors() method. Each entry records which helper was called, the normalized exceptions-map source (`exceptions`/`exceptions.exact`/`exceptions.broad`/`by_url.exact`/`by_url.broad`/`other`), a raw-string rendering of the source expression (anti-rot hatch), the resolved safe* binding for arg[1], and the unique resolved safe* binding referenced anywhere in arg[2] when one can be proven. Alias chains like `errorInfo = message` are followed before resolution. |
| 1.6.0 | 2026-04 | Stabilize error_code_fields contract. (1) Add `object_path` — derivation path from response to the safe* call's object, resolving opaque variable names like `firstEntry`. (2) Change `sentinel_values` from `[string]` to `[{value, operator}]` for polarity detection. (3) Child exchanges inherit `handle_errors` from parent when they don't override it. Role mapping stays single-helper: `throwExactlyMatchedException` → `error_code`, `throwBroadlyMatchedException` → `error_message`; fields hit by both accumulate dual roles. |
| 1.5.0 | 2026-04 | Add `roles` and `sentinel_values` to `ErrorCodeFieldEntry`. Each entry is now classified by how its value is used: `error_code` (passed to `throwExactlyMatchedException`), `error_message` (passed to `throwBroadlyMatchedException`), `status_sentinel` (compared against literals via `===`/`!==`). A field can have multiple roles. `sentinel_values` captures the comparison literals. |
| 1.4.0 | 2026-04 | Add `structure.authenticated_sections` — sorted list of API section names proven to require authentication via `checkRequiredCredentials()` gates in sign() AST. Handles direct `api === 'X'`, array-indexed `api[N] === 'X'` (coinbase-style), and indirect variable bindings. Null when sign() absent; `[]` when no gates found. |
| 1.3.0 | 2026-04 | Add `structure.handle_errors.error_code_fields` — derived list of `this.safeString/safeString2/safeValue` calls from handleErrors() AST. Each entry records object, field name, method, and alternate field. Replaces consumer hardcoded field name heuristics. |
| 1.2.0 | 2026-04 | Add `runtime.url_templates` — raw sign() probes per API section. Each entry: `api_param`, `http_method`, `sample_path` (inputs), `resolved_url` (output), `url_prefix` (derived when provable). Reveals path prefixes injected by `sign()` (e.g., OKX `/api/v5/`, Gate `/spot/`). |
| 1.1.0 | 2026-04 | Add `structure.unified_endpoints` — maps unified methods to interface method names they call. Derived exchanges inherit parent mappings. |
| 1.0.1 | 2026-04 | Add `runtime.symbol_patterns` — derived per-type formatting rules (separator, case, suffix, anomalies) for symbol conversion. |
| 1.0.0 | 2026-03 | Initial release. Two-layer model (runtime + structure), 110 exchanges, full ESTree AST bodies. |

---

## What This Contract Does NOT Cover

- **CCXT version compatibility** — a given schema version may be extracted from different CCXT releases. The `ccxt_version` field tracks which release was used; the schema contract is independent.
- **Extraction timing** — `extracted_at` is informational. The contract makes no guarantees about freshness.
- **Market data accuracy** — `loadMarkets()` data reflects exchange state at extraction time. It may be stale.
- **AST node exhaustiveness** — ESTree node types are permissive (`additionalProperties: true`). The schema validates structure, not every possible AST node shape.
- **Field ordering** — JSON key order is not guaranteed and must not be relied upon.
- **Cross-field semantic invariants** — the JSON Schema enforces shape, not coherence between fields. `mix ccxt_extract.contract_test` owns that layer: it asserts, for example, that every `structure.unified_endpoints` key is claimed in `runtime.describe.has`, and that every `structure.authenticated_sections` entry is reachable in `runtime.describe.api`. Schema-valid output can still fire contract-test findings; those are drift signals, not schema violations.

---

## Override Contract (v1)

Per-exchange curated overrides live at `priv/overrides/<exchange_id>.json`. They carry knowledge the AST walker and runtime probes cannot reach — imperative signing quirks, exchange-specific inversions, CCXT bugs — and form the third tier of the raw / derived / override model (see `CLAUDE.md` § "Raw vs Derived vs Override").

**This contract versions independently of the exchange JSON `schema_version`.** Override files carry their own `"schema_version": "1"`. Bumping the exchange schema does not imply an override-contract bump, and vice versa.

**JSON Schema:** `priv/schema/override_v1.json` (validated by `mix ccxt_extract.contract_test` via the `override_registry_valid` invariant).

### File format

```json
{
  "schema_version": "1",
  "overrides": [
    {
      "path": "/structure/authenticated_sections",
      "value": ["private"],
      "reason": "sign() has no checkRequiredCredentials() gate — credentials checked per-method",
      "verified_against": "priv/ccxt/ts/src/hyperliquid.ts:4877"
    }
  ]
}
```

### Rules

| Key | Required | Notes |
|-----|----------|-------|
| `schema_version` | yes | Must be `"1"`. Any other value is a hard error. |
| `overrides` | yes | Non-empty array of entries. Paths within a file must be unique. |
| `overrides[].path` | yes | RFC 6901 JSON Pointer into the emitted exchange JSON (`/structure/...`, `/runtime/describe/...`). Must start with `/`. |
| `overrides[].value` | yes | Any JSON value. Replaces whatever derivation produced for that path. |
| `overrides[].reason` | yes | Non-empty string. Why this override exists. Overrides without a reason rot silently. |
| `overrides[].verified_against` | optional | Source citation (`file:line`) or runtime probe reference proving the override matches real behavior. |
| `overrides[].unverified` | optional (default `false`) | Set `true` for best-effort overrides that have not been validated. **Mutually exclusive with `verified_against`** — the loader raises if both are present. |

### Parent-chain inheritance

Alias exchanges (e.g. `gateio` → `gate`, `huobi` → `htx`) inherit their parent's override when they don't have their own file. Inheritance walks the `class_hierarchy.json` parent chain; an alias can still override specific paths by shipping its own file that sets just those paths.

### Task-60 scope vs future tiers

Task 60 ships the contract, the `CcxtExtract.OverrideRegistry` loader, the JSON Schema, and the `override_registry_valid` contract-test invariant. **Task 61b** (shipped 2026-04-16) ships the generic merge stage: every override entry applies to the emitted exchange map at the tail of `Pipeline.extract/1` via `OverrideRegistry.apply_all/2`. All 14 shipped override files flow end-to-end; any RFC 6901 path in an override file takes effect — not just `/structure/authenticated_sections`.

**Current limits.** Shallow string-key pointers only. Numeric/array-index segments (e.g. `/path/0/name`) raise until **Task 104** lands — low urgency; no evidence of need as of 2026-04-17. Invalid override applications are rescued and logged at the callsite so one corrupt file cannot brick the full build; the `override_paths_present_in_output` contract-test invariant surfaces drift (override value absent at its pointer path) at build-check time.

**Provenance tagging** — the parallel `_provenance` map marking each field `"raw"` / `"derived"` / `"override"` — shipped in **Task 61a** (2026-04-17) as an additive, nullable field at schema 1.8.1, and was promoted to required, non-null at **Task 61c** / schema 2.0.0 (2026-04-17). Override-applied paths get their provenance entry flipped from `"derived"` (or `"raw"`) to `"override"` at the tail of `Pipeline.extract/1`.

**Exchange schema at 2.0.0.** The `_provenance` promotion is the breaking change. The override contract stays at v1 across this bump — override file format is unchanged.

---

## Signing Recipe (2.2.0+)

`structure.sign_recipe` is a declarative per-section signing recipe shipped at schema 2.2.0. A consumer reading the recipe for an authenticated section can construct an authenticated HTTP request without walking the raw `sign()` AST.

**JSON Schema:** `priv/schema/sign_recipe_v1.json` — standalone, reusable for external consumers. Kept in lockstep with `exchange_v3.json#/$defs/SignRecipeRecord` (parity checked by `test/ccxt_extract/sign_recipe_test.exs`).

### Shape

```jsonc
{
  "structure": {
    "sign_recipe": {
      "private": {
        "crypto_op": {"algo": "hmac_sha256"},      // Task 65
        "canonical_string": {                       // Tasks 66a + 66b (both populated)
          "GET": {
            "family": "hmac_simple",
            "components": [
              {"source": "timestamp"},
              {"source": "method"},
              {"source": "path"},
              {"source": "literal", "value": "?"},
              {"source": "query"}
            ],
            "encoding": "url_encoded"
          },
          "POST": {                                  // Task 66b — HMAC-with-body
            "family": "hmac_with_body",
            "components": [
              {"source": "timestamp"},
              {"source": "method"},
              {"source": "path"},
              {"source": "body"}
            ],
            "encoding": "url_encoded"
          }
        },
        "signature_placement": {                    // Task 65
          "location": "header",
          "key": "OK-ACCESS-SIGN"
        },
        "auth_headers": [                           // Task 67
          {"name": "OK-ACCESS-KEY", "source": "api_key"},
          {"name": "OK-ACCESS-PASSPHRASE", "source": "passphrase"},
          {"name": "OK-ACCESS-TIMESTAMP", "source": "timestamp"}
        ],
        "nonce": {"source": "timestamp_ms", "format": "iso8601"},  // Task 67
        "pre_sign_transforms": [                    // Task 68
          {"op": "base64_encode", "target": "signature"}
        ],
        "unresolved_reason": null,                  // auto-flipped by Task 69 biconditional
        "patch_count": 0
      },
      "sapi": { /* … same shape … */ }
    }
  }
}
```

See `SignRecipeRecord` under [Key Type Definitions](#key-type-definitions) for the enum tables of every field.

### Why per-section

Real exchanges vary signing per API section:

- **binance** emits 13 recipe entries (one per `private`, `sapi`, `sapiV2`, `fapiPrivate`, `fapiPrivateV3`, `eapiPrivate`, `papi`, …). Most share HMAC-SHA256+query but some don't.
- **bybit** splits GET (query canonical) vs POST (body canonical) inside `sign()` — section-level granularity captures the divergence.
- **okx / coinbase / kucoin** each carry multiple versioned private sections with different header conventions.

Keying the recipe on section name (mirroring `runtime.url_templates`) is the only honest way to represent this. Identical-looking sections still get their own entry — a consumer reading `sign_recipe[section]` always finds a record without disambiguating upstream.

### Keys mirror authenticated_sections

`Map.keys(sign_recipe)` **must equal** `authenticated_sections` as sets. Enforced by the `sign_recipe_keys_match_auth_sections` contract-test invariant and maintained by `Pipeline.sync_sign_recipe/1`, which runs after override merge so override-driven changes to `authenticated_sections` propagate into recipe key coverage automatically. An override that wants to target specific recipe fields (e.g. `/structure/sign_recipe/private/crypto_op`) survives the sync — keys present in both the post-override `authenticated_sections` and the post-override recipe map keep their values.

Exchanges with no authenticated sections emit `"sign_recipe": {}`.

### Null-by-default + unresolved_reason

Every derivation field starts `null` with `unresolved_reason: "not_yet_derived"` in 2.2.0. Phase 10 tasks 65–69 flip individual subsets of fields to derived values. When every derivation field is non-null, `SignRecipe.Derive` auto-flips `unresolved_reason` to `null` at emit time (shipped Task 69, 2026-04-24 — biconditional enforced in both directions by the `sign_recipe_honesty_valid` contract invariant). Before the flip, the closed-vocabulary `unresolved_reason` enum (`not_yet_derived` / `custom_signing_family` / `ambiguous_ast` / `no_sign_method`) tells consumers why a field is still null.

Consumers that encounter a null derivation field must either read the raw `structure.sign_method` AST or fall back to an override — per the Honesty Rule, no silent guesses.

### Three-Strikes counter

`patch_count` starts at `0` and bumps each time a Phase 10 derivation rule gets patched to handle a new edge case for a given recipe. At `3`, the knowledge migrates to `priv/overrides/<id>.json` instead of accreting further special cases in derivation. See CLAUDE.md § "Three-Strikes Rule" for the full workflow.

### Contract invariants

- `sign_recipe_keys_match_auth_sections` — per-exchange. Fails on any key in `authenticated_sections` without a recipe entry, or any recipe entry not in `authenticated_sections`.
- `sign_recipe_shape_valid` — per-exchange. Belt-and-suspenders over each recipe record: required keys present, `patch_count` is a non-negative integer, `unresolved_reason` is null or in the closed vocabulary. Deeper shape/enum validation lives in `Validation.validate_schema/2` against `exchange_v3.json#/$defs/SignRecipeRecord`.
- `sign_recipe_honesty_valid` — per-exchange. Enforces the biconditional: `unresolved_reason == null` iff every one of the six derivation fields is non-null. Fails loudly if a record carries `unresolved_reason: null` with any null derivation field (left→right violation — upstream Derive bug), or carries a non-null tag with all six fields populated (right→left violation — stale tag that should have been auto-flipped). Shipped Task 69, 2026-04-24.

### Populate order

Phase 10 bundles populate fields in this order (see ROADMAP.md § Phase 10):

| Task | What it fills | Status |
|------|---------------|--------|
| 65 | `crypto_op`, `signature_placement` | ✅ Shipped 2026-04-18 |
| 66a | `canonical_string` (HMAC-simple entries; per-verb map) | ✅ Shipped 2026-04-19 |
| 66b | `canonical_string` (HMAC-with-body entries; per-verb map) | ✅ Shipped 2026-04-21 (no schema bump — 2.3.0 slot fill) |
| 67 | `auth_headers`, `nonce` | ✅ Shipped 2026-04-24 (no schema bump — 2.2.0 slot fill) |
| 68 | `pre_sign_transforms` | ✅ Shipped 2026-04-24 |
| 69 | Biconditional contract: auto-flip `unresolved_reason` to `null` once all fields non-null (write-side) + `sign_recipe_honesty_valid` invariant (read-side) | ✅ Shipped 2026-04-24 |

JWT / RSA / Ed25519 and outlier signing families (Tasks 66c / 66d) are deferred — no Tier 1/2/DEX exchange in `priv/priority_tiers.json` needs them as of 2026-04-18.

---

## Testnet URL Catalog (2.4.0+)

`runtime.testnet_urls` is a structured, required, derived field that
replaces reaching into the opaque `runtime.describe.urls.test` /
`runtime.describe.options.sandboxMode` blobs. Shipped at schema 2.4.0
(Task 100, 2026-04-19).

### Shape

```json
"testnet_urls": {
  "pattern": "separate_host" | "sandbox_flag" | "none",
  "urls": { "public": "...", "private": "..." } | null,
  "sandbox_flag_field": "sandboxMode" | null,
  "unresolved_reason": null | "no_testnet_data"
}
```

See `$defs/TestnetUrls` in `priv/schema/exchange_v3.json` for the
canonical definition.

### Pattern classification

| `pattern` | When | `urls` | `sandbox_flag_field` | `unresolved_reason` |
|---|---|---|---|---|
| `"separate_host"` | `describe.urls.test` is a non-empty map | Non-null; CCXT's shape preserved (flat section map or nested host → section map), with `{hostname}` placeholders resolved against `describe.hostname` | May be null OR `"sandboxMode"` — not mutually exclusive | `null` |
| `"sandbox_flag"` | `urls.test` absent/empty but `options.sandboxMode` key exists | `null` | `"sandboxMode"` | `null` |
| `"none"` | Neither signal present | `null` | `null` | `"no_testnet_data"` |

### Why `sandbox_flag_field` is independent of `pattern`

Several priority exchanges (okx, gate, hyperliquid) carry BOTH a
testnet URL entry AND a `sandboxMode` flag. The separate host might
be the same host with a different path, or a true separate testnet
host that ALSO needs the flag set — the truth is "both." A pure enum
on `pattern` alone would force a lossy choice. Tracking flag presence
independently lets a consumer write one deterministic adapter:

```text
testnet_urls.urls   → base URL to hit for sandbox traffic
testnet_urls.sandbox_flag_field → name of the runtime flag to set (e.g. pass through to setSandboxMode)
```

### `{hostname}` resolution

When `describe.urls.test` string leaves contain `{hostname}` templates,
they are substituted with `describe.hostname` at extract time so
consumers never see placeholders. If `hostname` is absent the literal
`{hostname}` survives and the `testnet_urls_shape_valid` contract
invariant flags it as a finding. No silent fallback: either the URL is
fully resolved or the extraction surfaces the gap.

### Contract invariants

- `testnet_urls_shape_valid` — per-exchange. Fails on: key-set drift,
  `pattern` not in the closed enum, cross-field inconsistency (e.g.
  `pattern: "none"` with `urls` non-nil), or any residual `{hostname}`
  placeholder in a resolved URL string.

### Provenance

`/runtime/testnet_urls` is tagged `"derived"` in
`CcxtExtract.Provenance.@derived_pointers`. The underlying raw inputs
(`describe.urls`, `describe.options`) remain tagged `"raw"` as part of
`/runtime/describe`.

### Proxy patterns — deferred

The roadmap entry mentioned "proxy patterns" alongside testnet URLs.
Grep confirms no priority exchange (`priv/priority_tiers.json` tier1 +
tier2 + DEX) ships a `proxyUrl` in `describe()`. The consumer contract
(`ccxt_client` `Exchange.new/2`) also does not model proxies today, so
there is no consumer action to unblock. If a future priority exchange
surfaces `proxyUrl`, `runtime.proxy_patterns` becomes a follow-up
derivation — not an expansion of `testnet_urls`.
