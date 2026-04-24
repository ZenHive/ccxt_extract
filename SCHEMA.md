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
if major != 3:
    raise ValueError(f"Unsupported schema version: {data['schema_version']}")
```

```rust
// Rust
let major: u32 = data["schema_version"].split('.').next().unwrap().parse()?;
assert_eq!(major, 3, "Unsupported schema version");
```

```elixir
# Elixir
case data do
  %{"schema_version" => "3." <> _} -> :ok
  %{"schema_version" => v} -> raise "Unsupported schema version: #{v}"
end
```

**Handle unknown fields gracefully.** Patch versions may add new nullable keys. Consumers should ignore fields they don't recognize rather than failing on them.

**Pin to a major version.** Your consumer code targets a major schema version (currently 3). Within that major version, all changes are backward-compatible (minor bumps use aliases to preserve old access paths).

---

## Version 3.0.0 — Current

**Status:** Active (released 2026-04-20, Task 117)

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
  `priv/schema/exchange_v2.json` is retained for one release so maintainers
  can diff; the next schema release will delete it.
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

**JSON Schema:** `exchange_v2.json` (retained one release after rename)

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

For complete type definitions (all fields, nesting, and constraints), see `exchange_v2.json` — the JSON Schema shipped in every output directory. The summary below covers the most-referenced types:

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

**JSON Schema:** `priv/schema/sign_recipe_v1.json` — standalone, reusable for external consumers. Kept in lockstep with `exchange_v2.json#/$defs/SignRecipeRecord` (parity checked by `test/ccxt_extract/sign_recipe_test.exs`).

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
        "pre_sign_transforms": null,                // Task 68
        "unresolved_reason": "not_yet_derived",
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
- `sign_recipe_shape_valid` — per-exchange. Belt-and-suspenders over each recipe record: required keys present, `patch_count` is a non-negative integer, `unresolved_reason` is null or in the closed vocabulary. Deeper shape/enum validation lives in `Validation.validate_schema/2` against `exchange_v2.json#/$defs/SignRecipeRecord`.
- `sign_recipe_honesty_valid` — per-exchange. Enforces the biconditional: `unresolved_reason == null` iff every one of the six derivation fields is non-null. Fails loudly if a record carries `unresolved_reason: null` with any null derivation field (left→right violation — upstream Derive bug), or carries a non-null tag with all six fields populated (right→left violation — stale tag that should have been auto-flipped). Shipped Task 69, 2026-04-24.

### Populate order

Phase 10 bundles populate fields in this order (see ROADMAP.md § Phase 10):

| Task | What it fills | Status |
|------|---------------|--------|
| 65 | `crypto_op`, `signature_placement` | ✅ Shipped 2026-04-18 |
| 66a | `canonical_string` (HMAC-simple entries; per-verb map) | ✅ Shipped 2026-04-19 |
| 66b | `canonical_string` (HMAC-with-body entries; per-verb map) | ✅ Shipped 2026-04-21 (no schema bump — 2.3.0 slot fill) |
| 67 | `auth_headers`, `nonce` | ✅ Shipped 2026-04-24 (no schema bump — 2.2.0 slot fill) |
| 68 | `pre_sign_transforms` | ⬜ |
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

See `$defs/TestnetUrls` in `priv/schema/exchange_v2.json` for the
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
