# Schema Versioning Contract

This document defines the stability promise for ccxt_extract's output format. Consumers (Elixir, Rust, Go, Python) rely on `schema_version` to know what they can safely depend on.

---

## The Contract

Every per-exchange JSON file and `_manifest.json` includes a `schema_version` field (currently `"4.0.0"`). This version follows **semver** (`MAJOR.MINOR.PATCH`):

| Change Type | Version Bump | Consumer Impact |
|-------------|-------------|-----------------|
| **Additive fields** — new nullable keys in existing sections | Patch (4.0.x) | Safe to ignore. Existing field access unaffected. |
| **Backward-compatible structural changes** — reorganized sections, renamed fields with temporary aliases that preserve old access paths | Minor (4.x.0) | Plan to update parsers. Old field access works during the alias period but aliases are eventually removed. |
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

**Pin to a major version.** Your consumer code targets a major schema version (currently 4). Within that major version, all changes are backward-compatible.

---

## Top-Level Structure

Every per-exchange JSON file has exactly these top-level keys (**all required, non-null where the schema marks them so**):

| Key | Type | Description |
|-----|------|-------------|
| `schema_version` | `"4.x.y"` | This contract version |
| `extracted_at` | string (ISO 8601) | When extraction ran |
| `ccxt_version` | string | CCXT npm package version used |
| `exchange` | ExchangeMeta | Exchange identity and metadata |
| `endpoints` | object | Unified ↔ interface mapping, request shape, pagination, transaction classification, handler dispatch |
| `auth` | object | `sign_method` AST, `sign_recipe`, `authenticated_sections`, `headers` |
| `errors` | object | `handle_errors`, `class_hierarchy`, `status_map`, `retry_classification`, `dispatch` |
| `rate_limits` | object | `buckets`, `per_endpoint_cost`, `endpoint_cost_binding` |
| `normalization` | object | `parse_methods_digest`, `field_maps`, `response_envelopes` |
| `markets` | object | `symbols_index`, `patterns`, `currencies` (Task 97), `precision_mode` (Task 98 planned) |
| `testnet` | object | Structured testnet / sandbox URL catalog |
| `raw` | object | Raw passthroughs — `describe`, `url_templates`, `class_info`, `method_inventory`, `overrides_meta` |
| `_provenance` | ProvenanceMap | Per-path source tags (raw / derived / override) |

`markets.currencies` (Task 97) is the compact runtime view: unified code → `{precision, networks, ...}` with `info` stripped. `null` when the exchange had no load_markets data or the discovery predates the capture. Networks unlock deposit/withdraw + tx modeling in consumers.

### Two-State Optionality

Every data field uses exactly two states:

- **Present** — extraction succeeded; value is a map, list, or object
- **null** — layer is missing, empty, or does not apply to this exchange

All keys are always materialized (never absent). Consumers check for `null`, never for key existence.

---

## Provenance Map

The `_provenance` field is a flat map keyed by RFC 6901 JSON Pointer strings. Every value is one of three string tiers:

- `"raw"` — direct passthrough from a discovery file. No transformation between the extractor and emission.
- `"derived"` — computed at assembly time by a derivation module (e.g. `SymbolPatterns.derive/2`, `AuthenticatedSections.derive/2`, `ErrorCodeFields.derive/1`). Still AST-provable; nothing hand-curated reached it.
- `"override"` — replaced by an entry in `priv/overrides/<id>.json` at the tail of `Pipeline.extract/1`. The override file carries a required `reason` explaining the divergence — consumers who want that context should read the override file directly.

**Source of truth for the pointer list:** `CcxtExtract.Provenance.raw_pointers/0` and `derived_pointers/0` in `lib/ccxt_extract/provenance.ex`. The corpus-global lists are the canonical definition; this document does not duplicate them (drift hazard).

**Granularity** is section + direct children. The map does not recurse to every leaf; it describes which MODULE produced the field. The exception is `/errors/handle_errors`, whose sub-keys split between raw and derived and therefore carry per-subkey tags.

**Override stamping.** When `priv/overrides/<id>.json` contains `{"path": "/auth/authenticated_sections", ...}`, the provenance value at that pointer flips from `"derived"` to `"override"`. Override paths deeper than default granularity (e.g. `/auth/sign_method/params/timestamp`) get added as new entries with value `"override"` — the ancestor entry (`/auth/sign_method`) keeps its `"raw"` tag because the rest of the sub-tree is still raw.

**Null semantics.** The tier describes where the field WOULD have come from, not whether it's currently populated. Many fields are `null` for many exchanges. Provenance still records the tier so consumers can distinguish "this is raw null, discovery had no data" from "this is override null, curator chose to erase upstream data."

**Override-pointer translation.** All committed override files in `priv/overrides/<id>.json` use legacy v3-shaped paths (`/structure/...`, `/runtime/...`). `CcxtExtract.OverrideRegistry.translate_pointer/1` rewrites them to v4 locations at apply time. New override files may use v4 paths directly — paths without a known v3 prefix pass through unchanged.

---

## Schema 4.0.0 — Current

**JSON Schema:** `exchange_v4.json` (included in every output directory).

**Why a major bump (vs additive 3.x):** the v4 cut reorganized top-level sections from producer-shaped (`runtime` / `structure`) to consumer-shaped (`endpoints` / `auth` / `errors` / `rate_limits` / `normalization` / `markets` / `testnet` / `raw`). Additive 3.x can grow new keys but cannot reorganize without breaking; one migration cost in exchange for a coherent stable contract.

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

**`_unresolved_reason`:** `null` when the `safeTicker` return pattern was found (even if many individual slots are `null`); a non-null string when the return structure isn't the slottable pattern — e.g. kucoin: `"non_safe_ticker_return:parseContractTicker"`. Full vocabulary:

- `"no_return_statement"` — no `ReturnStatement` present in the body
- `"non_safe_ticker_return:<callee>"` — a different `this.<callee>(...)` call
- `"identifier_return"` — bare Identifier (pre-built variable returned directly)
- `"unrecognized_return_shape"` — any other non-slottable return argument

`TSAsExpression` wrappers are unwrapped before classification. Inheriting exchanges (no `parseTicker` override) emit `field_maps["ticker"] = null`.

**Honesty contract:** every populated slot is provable from AST. No field is synthesized or inferred from exchange documentation. `_unresolved_reason` is either `null` or one of the four strings above (two are prefix-bearing with open suffixes: `non_safe_ticker_return:*` and the others are exact). `coercion` and `format` are closed (hard-error on unrecognized); `key` is open (any wire-format string from the exchange).

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

---

## Key Type Definitions

For complete type definitions (all fields, nesting, and constraints), see `exchange_v4.json` — the JSON Schema shipped in every output directory. The summary below covers the most-referenced types:

- **MethodAST** — `{ async, params, return_type, statements, body }` where `body` is a complete ESTree BlockStatement
- **InterfaceSignature** — `{ name, params, return_type }` (no body — these are type declarations, not implementations)
- **MethodParam** — `{ name, type }` where `type` is the TypeScript type annotation or null
- **ASTNode** — ESTree nodes with `type`, `start`, `end` (byte offsets), plus node-specific fields
- **HandleErrorsData** — `{ method, exceptions, http_exceptions, error_code_fields, throw_dispatches }` where `method` is a MethodAST, `exceptions` maps error strings to class names (keyed by `broad`/`exact` plus market types), `http_exceptions` maps HTTP status codes to class names, `error_code_fields` is a list of ErrorCodeFieldEntry, and `throw_dispatches` is a list of ThrowDispatchEntry
- **ErrorCodeFieldEntry** — `{ object, object_path, field, method, field2, roles, sentinel_values }` — a single `this.safe*()` call from handleErrors() with role classification. `object` is the first arg identifier (e.g., `"response"`, `"error"`), `object_path` is the derivation path tracing back to `response` (e.g., `["response", "data", "failure", "0"]`) or null for trivial cases. `field` is the literal field name accessed, `method` is `"safeString"` / `"safeString2"` / `"safeValue"`, `field2` is the alternate field for safeString2. `roles` is an array of `"error_code"` / `"error_message"` / `"status_sentinel"` classified by the CCXT helper: `throwExactlyMatchedException` → `error_code` (exact-map lookup key — not necessarily numeric, e.g., OKX's `sCode` is a string), `throwBroadlyMatchedException` → `error_message` (message text scanned for substrings of `exceptions.broad` keys), `===`/`!==` comparisons → `status_sentinel`. A field hit by both throw helpers in the same handleErrors() accumulates both roles. `sentinel_values` is an array of `{ value, operator }` objects where `operator` is `"==="` or `"!=="` (for polarity detection), sorted by value, or null when no sentinel role.
- **ThrowDispatchEntry** — `{ helper, exceptions_source, exceptions_source_raw, lookup, message_lookup }` — a single `this.throwExactlyMatchedException()` / `this.throwBroadlyMatchedException()` call from handleErrors(). `exceptions_source` normalizes arg[0] to `"exceptions"`, `"exceptions.exact"`, `"exceptions.broad"`, `"by_url.exact"`, `"by_url.broad"`, or `"other"`; `exceptions_source_raw` preserves the original expression as a compact string. `lookup` is the resolved safe* binding for arg[1]. `message_lookup` is the unique resolved safe* binding referenced anywhere inside arg[2] (including aliases like `errorInfo = message` and wrappers like `this.json(message)`), or null when the message expression does not point at a single bound lookup value.
- **PaginationEntry** — `{ strategy, containing_method, target_method, max_entries_per_request, ... }` where `strategy` is one of `"dynamic"`, `"deterministic"`, `"cursor"`, `"incremental"`. `containing_method` is the method body where the call was found; `target_method` is the method name passed to `fetchPaginatedCall*` (null for unresolved variable references). Strategy-specific fields: cursor has `cursor_received`, `cursor_sent`, `cursor_increment`; incremental has `page_key`. Null values mean the parameter was not statically resolvable from source.
- **OverridesData** — `{ extends, rest, ws }` where `extends` is the parent exchange id, and each entry contains `overridden` (methods redefined from parent, with AST), `new_methods` (methods not on parent), and `inherited` (method names only)
- **SignRecipeRecord** — `{ crypto_op, canonical_string, signature_placement, auth_headers, nonce, pre_sign_transforms, unresolved_reason, patch_count }`. All derivation fields are nullable — scaffold defaults every field to `null`. `crypto_op`: `{ algo ∈ "hmac_sha256" | "hmac_sha512" | "hmac_sha384" | "ed25519" | "rsa" | "custom", reason? }`. `canonical_string`: `{ family ∈ "hmac_simple" | "hmac_with_body" | "jwt" | "custom", components: [{ source, value? }], encoding ∈ "url_encoded" | "json" | "raw" }` where `source` ∈ `"timestamp" | "api_key" | "recv_window" | "method" | "path" | "query" | "body" | "literal"`. `signature_placement`: `{ location ∈ "header" | "query" | "body", key }`. `auth_headers`: `[{ name, source ∈ "api_key" | "passphrase" | "timestamp" | "signature" | "recv_window" | "literal", value? }]` — excludes the signature header itself (use `signature_placement` for that). `nonce`: `{ source ∈ "timestamp_ms" | "timestamp_sec" | "timestamp_us" | "timestamp_ns" | "monotonic" | "exchange_supplied", format ∈ "integer" | "iso8601" | "hex" | "string" }`. `pre_sign_transforms`: `[{ op ∈ "hex_encode" | "base64_encode" | "lowercase" | "url_encode" | "json_encode", target ∈ "signature" | "body" | "canonical_string" }]`. `unresolved_reason`: `null` | `"not_yet_derived"` | `"custom_signing_family"` | `"ambiguous_ast"` | `"no_sign_method"` — must be `null` if and only if every derivation field above is non-null (enforced by the `sign_recipe_honesty_valid` contract invariant). `patch_count`: non-negative integer, Three-Strikes counter (see CLAUDE.md). Standalone JSON Schema at `priv/schema/sign_recipe_v1.json`.
- **RequestDefaultsEntry** — `{ value, kind, reason }` where `kind` ∈ `"literal" | "unresolved"`. For `literal`: `value` is the resolved primitive (string/number/boolean/null), a map of string keys → primitives (nested literal), or a list of primitives (array of literals); `reason` is null. For `unresolved`: `value` is null; `reason` ∈ `"conditional_value"` (ternary/logical expression), `"identifier_reference"` (variable or member access), `"dynamic_construction"` (call, binary, template literal, partially-literal object/array), `"computed_key"` (key was a computed `[expr]`), `"spread_elaboration"` (reserved for future spread tracking). Keys preserve the exchange's own literal string keys; computed keys surface as the synthetic key `"_computed"`.
- **ClassInfo** — `{ rest, ws }` where each is a ClassEntry with `class_name`, `extends_resolved`, `parent_key`, `file`, `method_count`, and optional `method_details`
- **MethodInventory** — `{ rest, ws }` where each is a list of MethodSignature (like MethodAST but without `body`)
- **ExchangeMeta** — `{ id, name, alias, certified, pro, version, country, referral, tier }` — exchange identity, CCXT metadata, plus `tier` ∈ `"tier1" | "tier2" | "tier3" | "dex" | "unclassified"` (hand-curated in `priv/priority_tiers.json`, not extracted from CCXT; `tier1`/`tier2`/`dex` are the buckets this project commits to deriving recipes for)

---

## Shared Artifacts

These files are **global** (not per-exchange) and live alongside `_manifest.json` in the output directory:

### `_base_methods.json`

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
| `tier_scope` | string \| string[] | Active scope stamped on write by `CcxtExtract.Scope.to_manifest_value/1`. `"all"` for unscoped / `--all` runs; otherwise a canonicalized list of scope tokens — tier names in canonical order (`"tier1"`, `"tier2"`, `"tier3"`, `"dex"`) followed by alphabetized `"exchange:<id>"` entries. Lets consumers detect partial aggregates produced by scoped extraction runs. |

---

## What This Contract Does NOT Cover

- **CCXT version compatibility** — a given schema version may be extracted from different CCXT releases. The `ccxt_version` field tracks which release was used; the schema contract is independent.
- **Extraction timing** — `extracted_at` is informational. The contract makes no guarantees about freshness.
- **Market data accuracy** — `loadMarkets()` data reflects exchange state at extraction time. It may be stale.
- **AST node exhaustiveness** — ESTree node types are permissive (`additionalProperties: true`). The schema validates structure, not every possible AST node shape.
- **Field ordering** — JSON key order is not guaranteed and must not be relied upon.
- **Cross-field semantic invariants** — the JSON Schema enforces shape, not coherence between fields. `mix ccxt_extract.contract_test` owns that layer: it asserts, for example, that every `endpoints.unified` key is claimed in `raw.describe.has`, and that every `auth.authenticated_sections` entry is reachable in `raw.describe.api`. Schema-valid output can still fire contract-test findings; those are drift signals, not schema violations.

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

**Note on legacy v3-shaped paths.** Committed override files were authored against the v3 schema and still use `/structure/...` and `/runtime/...` pointers. `OverrideRegistry.translate_pointer/1` rewrites them to v4 locations (`/auth/...`, `/raw/...`, `/endpoints/...`, etc.) at apply time. New override files may use v4 paths directly — unknown prefixes pass through unchanged.

### Rules

| Key | Required | Notes |
|-----|----------|-------|
| `schema_version` | yes | Must be `"1"`. Any other value is a hard error. |
| `overrides` | yes | Non-empty array of entries. Paths within a file must be unique. |
| `overrides[].path` | yes | RFC 6901 JSON Pointer into the emitted exchange JSON. Must start with `/`. |
| `overrides[].value` | yes | Any JSON value. Replaces whatever derivation produced for that path. |
| `overrides[].reason` | yes | Non-empty string. Why this override exists. Overrides without a reason rot silently. |
| `overrides[].verified_against` | optional | Source citation (`file:line`) or runtime probe reference proving the override matches real behavior. |
| `overrides[].unverified` | optional (default `false`) | Set `true` for best-effort overrides that have not been validated. **Mutually exclusive with `verified_against`** — the loader raises if both are present. |

### Parent-chain inheritance

Alias exchanges (e.g. `gateio` → `gate`, `huobi` → `htx`) inherit their parent's override when they don't have their own file. Inheritance walks the `class_hierarchy.json` parent chain; an alias can still override specific paths by shipping its own file that sets just those paths.

### Current limits

Shallow string-key pointers only. Numeric/array-index segments (e.g. `/path/0/name`) raise until **Task 104** lands. Invalid override applications are rescued and logged at the callsite so one corrupt file cannot brick the full build; the `override_paths_present_in_output` contract-test invariant surfaces drift (override value absent at its pointer path) at build-check time.

**Provenance tagging.** Override-applied paths get their `_provenance` entry flipped from `"derived"` (or `"raw"`) to `"override"` at the tail of `Pipeline.extract/1`.

---

## Signing Recipe

`auth.sign_recipe` is a declarative per-section signing recipe. A consumer reading the recipe for an authenticated section can construct an authenticated HTTP request without walking the raw `sign()` AST.

**JSON Schema:** `priv/schema/sign_recipe_v1.json` — standalone, reusable for external consumers. Kept in lockstep with `exchange_v4.json#/$defs/SignRecipeRecord` (parity checked by `test/ccxt_extract/sign_recipe_test.exs`).

### Shape

```jsonc
{
  "auth": {
    "sign_recipe": {
      "private": {
        "crypto_op": {"algo": "hmac_sha256"},
        "canonical_string": {
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
          "POST": {
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
        "signature_placement": {
          "location": "header",
          "key": "OK-ACCESS-SIGN"
        },
        "auth_headers": [
          {"name": "OK-ACCESS-KEY", "source": "api_key"},
          {"name": "OK-ACCESS-PASSPHRASE", "source": "passphrase"},
          {"name": "OK-ACCESS-TIMESTAMP", "source": "timestamp"}
        ],
        "nonce": {"source": "timestamp_ms", "format": "iso8601"},
        "pre_sign_transforms": [
          {"op": "base64_encode", "target": "signature"}
        ],
        "unresolved_reason": null,
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

Keying the recipe on section name (mirroring `raw.url_templates`) is the only honest way to represent this. Identical-looking sections still get their own entry — a consumer reading `sign_recipe[section]` always finds a record without disambiguating upstream.

### Keys mirror authenticated_sections

`Map.keys(sign_recipe)` **must equal** `auth.authenticated_sections` as sets. Enforced by the `sign_recipe_keys_match_auth_sections` contract-test invariant and maintained by `Pipeline.sync_sign_recipe/1`, which runs after override merge so override-driven changes to `authenticated_sections` propagate into recipe key coverage automatically. An override that wants to target specific recipe fields (e.g. `/auth/sign_recipe/private/crypto_op`) survives the sync — keys present in both the post-override `authenticated_sections` and the post-override recipe map keep their values.

Exchanges with no authenticated sections emit `"sign_recipe": {}`.

### Null-by-default + unresolved_reason

Every derivation field starts `null` with `unresolved_reason: "not_yet_derived"` and is flipped to a derived value as Phase 10 tasks 65–69 populate individual subsets of fields. When every derivation field is non-null, `SignRecipe.Derive` auto-flips `unresolved_reason` to `null` at emit time (biconditional enforced in both directions by the `sign_recipe_honesty_valid` contract invariant). Before the flip, the closed-vocabulary `unresolved_reason` enum (`not_yet_derived` / `custom_signing_family` / `ambiguous_ast` / `no_sign_method`) tells consumers why a field is still null.

Consumers that encounter a null derivation field must either read the raw `auth.sign_method` AST or fall back to an override — per the Honesty Rule, no silent guesses.

### Three-Strikes counter

`patch_count` starts at `0` and bumps each time a Phase 10 derivation rule gets patched to handle a new edge case for a given recipe. At `3`, the knowledge migrates to `priv/overrides/<id>.json` instead of accreting further special cases in derivation. See CLAUDE.md § "Three-Strikes Rule" for the full workflow.

### Contract invariants

- `sign_recipe_keys_match_auth_sections` — per-exchange. Fails on any key in `authenticated_sections` without a recipe entry, or any recipe entry not in `authenticated_sections`.
- `sign_recipe_shape_valid` — per-exchange. Belt-and-suspenders over each recipe record: required keys present, `patch_count` is a non-negative integer, `unresolved_reason` is null or in the closed vocabulary. Deeper shape/enum validation lives in `Validation.validate_schema/2` against `exchange_v4.json#/$defs/SignRecipeRecord`.
- `sign_recipe_honesty_valid` — per-exchange. Enforces the biconditional: `unresolved_reason == null` iff every one of the six derivation fields is non-null. Fails loudly if a record carries `unresolved_reason: null` with any null derivation field (left→right violation — upstream Derive bug), or carries a non-null tag with all six fields populated (right→left violation — stale tag that should have been auto-flipped).

JWT / RSA / Ed25519 and outlier signing families (Tasks 66c / 66d) are deferred — no Tier 1/2/DEX exchange in `priv/priority_tiers.json` needs them as of 2026-04-18.

---

## Testnet URL Catalog

`testnet` is a structured, required, derived top-level section that replaces reaching into the opaque `raw.describe.urls.test` / `raw.describe.options.sandboxMode` blobs.

### Shape

```json
"testnet": {
  "pattern": "separate_host" | "sandbox_flag" | "none",
  "urls": { "public": "...", "private": "..." } | null,
  "sandbox_flag_field": "sandboxMode" | null,
  "unresolved_reason": null | "no_testnet_data"
}
```

See `$defs/TestnetUrls` in `priv/schema/exchange_v4.json` for the canonical definition.

### Pattern classification

| `pattern` | When | `urls` | `sandbox_flag_field` | `unresolved_reason` |
|---|---|---|---|---|
| `"separate_host"` | `describe.urls.test` is a non-empty map | Non-null; CCXT's shape preserved (flat section map or nested host → section map), with `{hostname}` placeholders resolved against `describe.hostname` | May be null OR `"sandboxMode"` — not mutually exclusive | `null` |
| `"sandbox_flag"` | `urls.test` absent/empty but `options.sandboxMode` key exists | `null` | `"sandboxMode"` | `null` |
| `"none"` | Neither signal present | `null` | `null` | `"no_testnet_data"` |

### Why `sandbox_flag_field` is independent of `pattern`

Several priority exchanges (okx, gate, hyperliquid) carry BOTH a testnet URL entry AND a `sandboxMode` flag. The separate host might be the same host with a different path, or a true separate testnet host that ALSO needs the flag set — the truth is "both." A pure enum on `pattern` alone would force a lossy choice. Tracking flag presence independently lets a consumer write one deterministic adapter:

```text
testnet.urls               → base URL to hit for sandbox traffic
testnet.sandbox_flag_field → name of the runtime flag to set (e.g. pass through to setSandboxMode)
```

### `{hostname}` resolution

When `describe.urls.test` string leaves contain `{hostname}` templates, they are substituted with `describe.hostname` at extract time so consumers never see placeholders. If `hostname` is absent the literal `{hostname}` survives and the `testnet_urls_shape_valid` contract invariant flags it as a finding. No silent fallback: either the URL is fully resolved or the extraction surfaces the gap.

### Contract invariants

- `testnet_urls_shape_valid` — per-exchange. Fails on: key-set drift, `pattern` not in the closed enum, cross-field inconsistency (e.g. `pattern: "none"` with `urls` non-nil), or any residual `{hostname}` placeholder in a resolved URL string.

### Provenance

`/testnet` is tagged `"derived"`. The underlying raw inputs (`describe.urls`, `describe.options`) remain tagged `"raw"` as part of `/raw/describe`.

### Proxy patterns — deferred

The roadmap entry mentioned "proxy patterns" alongside testnet URLs. Grep confirms no priority exchange (`priv/priority_tiers.json` tier1 + tier2 + DEX) ships a `proxyUrl` in `describe()`. The consumer contract (`ccxt_client` `Exchange.new/2`) also does not model proxies today, so there is no consumer action to unblock. If a future priority exchange surfaces `proxyUrl`, `raw.proxy_patterns` becomes a follow-up derivation — not an expansion of `testnet`.
