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
if major != 1:
    raise ValueError(f"Unsupported schema version: {data['schema_version']}")
```

```rust
// Rust
let major: u32 = data["schema_version"].split('.').next().unwrap().parse()?;
assert_eq!(major, 1, "Unsupported schema version");
```

```elixir
# Elixir
case data do
  %{"schema_version" => "1." <> _} -> :ok
  %{"schema_version" => v} -> raise "Unsupported schema version: #{v}"
end
```

**Handle unknown fields gracefully.** Patch versions may add new nullable keys. Consumers should ignore fields they don't recognize rather than failing on them.

**Pin to a major version.** Your consumer code targets a major schema version (currently 1). Within that major version, all changes are backward-compatible (minor bumps use aliases to preserve old access paths).

---

## Version 1.8.0 — Current

**Status:** Active

**JSON Schema:** `exchange_v1.json` (included in every output directory)

### Top-Level Structure

Every per-exchange JSON file has exactly these top-level keys (all required, never absent):

| Key | Type | Description |
|-----|------|-------------|
| `schema_version` | `"1.8.0"` | This contract version |
| `extracted_at` | string (ISO 8601) | When extraction ran |
| `ccxt_version` | string | CCXT npm package version used |
| `exchange` | ExchangeMeta | Exchange identity and metadata |
| `runtime` | RuntimeData | QuickBEAM-extracted values |
| `structure` | StructureData | OXC AST-extracted structure |

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
| `authenticated_sections` | string[] or null | API sections proven to require authentication via `checkRequiredCredentials()` gates in sign() AST. Handles `api === 'X'` and `api[N] === 'X'` patterns. Sorted. Null when sign() absent; empty list when sign() exists but no `checkRequiredCredentials()` gates found. Note: some exchanges authenticate without `checkRequiredCredentials()` — use `sign_method` AST for broader auth detection. |
| `handle_errors` | HandleErrorsData or null | `handleErrors()` AST plus exception mappings |
| `parse_methods` | map(name -> MethodAST) or null | `parse*()` methods with AST bodies |
| `ws_methods` | map(name -> MethodAST) or null | `watch*()` / `handle*()` WS methods with AST bodies |
| `interface_signatures` | map(name -> InterfaceSignature) or null | Typed API method signatures from `abstract/*.ts` |
| `pagination` | map(name -> [PaginationEntry]) or null | Per-method pagination strategy and parameters (always arrays; `_unresolved` key for variable method names) |
| `overrides` | OverridesData or null | Method override analysis for derived exchanges |
| `unified_endpoints` | map(name -> string[]) or null | Unified method → interface method mappings (e.g., `fetchTicker` → `["publicGetV5MarketTickers"]`) |

### Key Type Definitions

For complete type definitions (all fields, nesting, and constraints), see `exchange_v1.json` — the JSON Schema shipped in every output directory. The summary below covers the most-referenced types:

- **MethodAST** — `{ async, params, return_type, statements, body }` where `body` is a complete ESTree BlockStatement
- **InterfaceSignature** — `{ name, params, return_type }` (no body — these are type declarations, not implementations)
- **MethodParam** — `{ name, type }` where `type` is the TypeScript type annotation or null
- **ASTNode** — ESTree nodes with `type`, `start`, `end` (byte offsets), plus node-specific fields
- **HandleErrorsData** — `{ method, exceptions, http_exceptions, error_code_fields, throw_dispatches }` where `method` is a MethodAST, `exceptions` maps error strings to class names (keyed by `broad`/`exact` plus market types), `http_exceptions` maps HTTP status codes to class names, `error_code_fields` is a list of ErrorCodeFieldEntry, and `throw_dispatches` is a list of ThrowDispatchEntry
- **ErrorCodeFieldEntry** — `{ object, object_path, field, method, field2, roles, sentinel_values }` — a single `this.safe*()` call from handleErrors() with role classification. `object` is the first arg identifier (e.g., `"response"`, `"error"`), `object_path` is the derivation path tracing back to `response` (e.g., `["response", "data", "failure", "0"]`) or null for trivial cases. `field` is the literal field name accessed, `method` is `"safeString"` / `"safeString2"` / `"safeValue"`, `field2` is the alternate field for safeString2. `roles` is an array of `"error_code"` / `"error_message"` / `"status_sentinel"` classified by the CCXT helper: `throwExactlyMatchedException` → `error_code` (exact-map lookup key — not necessarily numeric, e.g., OKX's `sCode` is a string), `throwBroadlyMatchedException` → `error_message` (message text scanned for substrings of `exceptions.broad` keys), `===`/`!==` comparisons → `status_sentinel`. A field hit by both throw helpers in the same handleErrors() accumulates both roles. `sentinel_values` is an array of `{ value, operator }` objects where `operator` is `"==="` or `"!=="` (for polarity detection), sorted by value, or null when no sentinel role.
- **ThrowDispatchEntry** — `{ helper, exceptions_source, exceptions_source_raw, lookup, message_lookup }` — a single `this.throwExactlyMatchedException()` / `this.throwBroadlyMatchedException()` call from handleErrors(). `exceptions_source` normalizes arg[0] to `"exceptions"`, `"exceptions.exact"`, `"exceptions.broad"`, `"by_url.exact"`, `"by_url.broad"`, or `"other"`; `exceptions_source_raw` preserves the original expression as a compact string. `lookup` is the resolved safe* binding for arg[1]. `message_lookup` is the unique resolved safe* binding referenced anywhere inside arg[2] (including aliases like `errorInfo = message` and wrappers like `this.json(message)`), or null when the message expression does not point at a single bound lookup value.
- **PaginationEntry** — `{ strategy, containing_method, target_method, max_entries_per_request, ... }` where `strategy` is one of `"dynamic"`, `"deterministic"`, `"cursor"`, `"incremental"`. `containing_method` is the method body where the call was found; `target_method` is the method name passed to `fetchPaginatedCall*` (null for unresolved variable references). Strategy-specific fields: cursor has `cursor_received`, `cursor_sent`, `cursor_increment`; incremental has `page_key`. Null values mean the parameter was not statically resolvable from source.
- **OverridesData** — `{ extends, rest, ws }` where `extends` is the parent exchange id, and each entry contains `overridden` (methods redefined from parent, with AST), `new_methods` (methods not on parent), and `inherited` (method names only)
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

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.8.0 | 2026-04 | Add optional `exchange.tier` field (`"tier1" \| "tier2" \| "tier3" \| "dex" \| "unclassified"`). Additive — consumers reading 1.7.1 still parse 1.8.0 output cleanly. Hand-curated in `priv/priority_tiers.json`; stamped by `CcxtExtract.Tiers.get_priority_tier/1` during pipeline assembly. |
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
