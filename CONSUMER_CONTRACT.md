# CONSUMER_CONTRACT

**Purpose:** Unfiltered checklist of every piece of knowledge a language-agnostic consumer (Rust, Elixir, Python, Go, macro-codegen in any language) needs to operate a CCXT exchange *without walking AST*. Phases 10–16 in [ROADMAP.md](ROADMAP.md) tick items off this list.

**Contract rule** (from [CLAUDE.md](CLAUDE.md)): every item here is either provable from CCXT source/runtime (raw or derived) or filled by a curated override. Consumers never walk AST in normal operation. Raw AST remains in the output as an escape hatch for debugging and novel needs.

**Status legend:** ✅ covered · 🚧 in progress · ⬜ open · ➖ not applicable

**Consumer scope (since 2026-05-20):** the sole consumer (`../ccxt_client/`) consumes a 7-exchange option-seller set. Regenerate its corpus with:

```bash
mix ccxt_extract.update --output /path/to/ccxt_client/priv/ccxt \
  --exchange binance,binanceusdm,bybit,deribit,derive,hyperliquid,okx
```

Derivation for these 7 is full; every other exchange is raw-only (`null + reason` for derived fields). See [CLAUDE.md](CLAUDE.md) § "Tier-based scoping (philosophy)".

---

## 1. Request signing

A consumer must be able to sign an authenticated request per API section without reading `sign()` source.

| Item | Status | Source |
|------|--------|--------|
| Per-section declarative signing recipe (schema scaffold) | 🚧 | `auth.sign_recipe` shipped at schema 2.2.0 (Task 64) — all derivation fields null, `unresolved_reason: "not_yet_derived"` until Tasks 65–69 populate. Keys mirror `auth.authenticated_sections`. |
| Crypto op (HMAC-SHA256/512, RSA, Ed25519, etc.) per section | 🚧 | `auth.sign_recipe.<section>.crypto_op` — shipped for priority exchanges via Task 65 (2026-04-18); binance/bybit honestly emit `ambiguous_ast` for multi-algo conditional sign(); hyperliquid emits `custom_signing_family`. |
| Signature placement (header name, query param name, body field) | 🚧 | `auth.sign_recipe.<section>.signature_placement` — shipped for 10 priority exchanges covering header / query / body placements via Task 65 (2026-04-18); htx-style indirect `request` object composition tracked as Task 113. |
| Canonical string recipe — HMAC-simple family | ✅ | `auth.sign_recipe.<section>.canonical_string` — shipped via Task 66a (2026-04-19); priority exchanges with multi-component or unusual sources (Deribit nonce/hostname, Phemex expiry, Gate/HTX delimited concat) honestly emit null with `unresolved_reason: "not_yet_derived"` — extension paths tracked in `roadmap/tasks.toml` follow-ups. |
| Canonical string recipe — HMAC-with-body family | ✅ | `auth.sign_recipe.<section>.canonical_string` — shipped via Task 66b (2026-04-21); kucoin / coinbaseexchange conditional body assignment patterns honestly emit null at recipe level — handled via overrides per Three-Strikes when a priority consumer needs them. |
| Canonical string recipe — JWT/RSA/Ed25519 family | 🔶 | Shape shipped at 2.2.0; Task 66c deferred — no priority exchange uses these |
| Canonical string recipe — custom/outlier family | 🔶 | Shape shipped at 2.2.0; Task 66d deferred — migrate via overrides per Three-Strikes |
| Auth header set (API key header, passphrase, signature, timestamp) | ✅ | `auth.sign_recipe.<section>.auth_headers` — populated by Task 67 (2026-04-24). Entries `{name, source}` where source ∈ `api_key \| passphrase \| timestamp \| recv_window \| literal`; signature headers are excluded (already captured in `signature_placement`). `[]` is a truthful "consumer has nothing extra to attach" for signature-only shapes like deribit / htx. `null` when the recipe is terminal (ambiguous_ast / custom_signing_family / no_sign_method). |
| Nonce/timestamp source (ms, sec, μs, monotonic, exchange-supplied) | ✅ | `auth.sign_recipe.<section>.nonce` — populated by Task 67 (2026-04-24). Shape `{source, format}` with source ∈ `timestamp_ms \| timestamp_sec \| timestamp_us \| timestamp_ns \| monotonic \| exchange_supplied` and format ∈ `integer \| iso8601 \| hex \| string`. Handles chained bindings (e.g. gate's `timestampString → timestamp → parseToInt(nonce / 1000)`) via terminal-binding filter + identifier-chain resolver. |
| Pre-sign transforms (hex-encode, base64, lowercase, URL-encode body) | ✅ | `auth.sign_recipe.<section>.pre_sign_transforms` — populated by Task 68 (2026-04-24). Ordered list of `{op, target}` entries where op ∈ `hex_encode \| base64_encode \| lowercase \| url_encode \| json_encode` and target ∈ `signature \| body \| canonical_string`. Detects: (1) hmac digest (4th arg of `this.hmac`, default hex when absent); (2) body JSON-encoding when `body = this.json(…)` is consumed by a crypto call; (3) post-signature wrappings (`this.urlencode({K: sig})`, `encodeURIComponent(sig)`, `sig.toLowerCase()`). Composite stacks (e.g. htx emits `[base64_encode/signature, url_encode/signature]`) are deduplicated. `[]` is the honest-empty case; `null` only on terminal unresolved_reason. |
| Which API sections require auth | ✅ | `auth.authenticated_sections` (Task 52). As of Task 123 (2026-04-24) the list also includes dotted `<parent>.<child>` paths (e.g. `contract.private`, `spot.private`) when `describe.api` nests authenticated children under container keys. Consumers must pattern-match on either tier. |
| Raw `sign()` AST (escape hatch) | ✅ | `auth.sign_method` |

---

## 2. Request building

Turning a unified method call into an HTTP request, excluding signing.

| Item | Status | Source |
|------|--------|--------|
| Unified method → interface method mapping | ✅ | `endpoints.unified` (Task 41) |
| Interface method → HTTP verb + path template | 🚧 | Partially in `raw.url_templates` (Task 46); Phase 11 — Task 70 |
| Path-param substitution rules (named placeholders) | ⬜ | Phase 11 — Task 70 |
| URL base per section + environment (live/testnet) | 🚧 | `raw.url_templates` partial; Phase 16 — Task 100 |
| Query string ordering / encoding rules | ⬜ | Phase 11 — Task 70 |
| Body encoding (JSON, form-urlencoded, custom) per section | ⬜ | Phase 11 — Task 71 |
| Content-Type header per section | ⬜ | Phase 11 — Task 71 |
| Timestamp source + format (when sent as header/param) | ⬜ | Phase 11 — Task 72 |
| Per-method rate-limit cost + weight axis | ⬜ | Phase 11 — Task 73 / Phase 14 |
| Pagination strategy per method | ✅ | `endpoints.pagination` (Task 32) |
| User-agent / default headers | ✅ | `auth.headers` (Task 73b, schema 3.1.0) |

---

## 3. Response parsing

For every `parse*` method, a consumer needs a declarative field map.

| Item | Status | Source |
|------|--------|--------|
| Success envelope paths per method group | ⬜ | Phase 12 — Task 83 |
| `parseTicker` field map + coercion + enums | ✅ | Phase 12 — Task 74 |
| `parseOrder` field map + status/side/type enums | ⬜ | Phase 12 — Task 75 |
| `parseTrade` field map + coercion | ⬜ | Phase 12 — Task 76 |
| `parseBalance` field map + coercion | ⬜ | Phase 12 — Task 77 |
| `parseOHLCV` field map + timestamp format | 🚧 | Phase 12 — Tasks 78/78b/78e/78f ✅ (array-input + object-input + parse8601 + market.spot discriminator); 78c/78d pending (hybrid Array.isArray, safeTimestamp) |
| `parseMarket` field map | ⬜ | Phase 12 — Task 79 |
| `parsePosition` field map | ⬜ | Phase 12 — Task 80 |
| `parseTransaction` (deposit/withdrawal) field map | ⬜ | Phase 12 — Task 81 |
| `parseDepositAddress` field map | ⬜ | Phase 12 — Task 82 |
| Raw `parse*` AST (escape hatch) | ✅ | `priv/discoveries/parse_methods.json` (discovery only since schema 3.0.0 / Task 117 — no longer emitted into per-exchange spec JSON; Phase 12 consumes from discoveries) |
| Type-coercion table per field (safeString/safeNumber/safeTimestamp) | ⬜ | Folded into each per-type task |
| Base normalizers (`safe*` implementations) reference | ✅ | `_base_methods.json` (Task 31) |

---

## 4. Error handling

| Item | Status | Source |
|------|--------|--------|
| Exchange error code → CCXT error class map (exact/broad) | ✅ | `raw.describe.exceptions` |
| Error code field name per response | ✅ | `errors.handle_errors.error_code_fields` (Task 49/53/54) |
| Throw-dispatch entries (code field ↔ message field pairing) | ✅ | `errors.handle_errors.throw_dispatches` (Task 55) |
| HTTP status → error class map per exchange | ⬜ | Phase 13 — Task 85 |
| Retryable classification (rate-limit/network/server-busy/auth) | ⬜ | Phase 13 — Task 86 |
| Error class hierarchy export (language-agnostic tree) | ✅ | `errors.class_hierarchy` (Task 87, schema 3.2.0). Three projections: `tree` (recursive), `flat_parents` (O(1) parent), `ancestors` (O(1) ancestor chain). |
| Handler routing tables (method → error handler) | ⬜ | Phase 13 — Task 88a |
| Handler routing tables (method → signing dispatch) | ⬜ | Phase 13 — Task 88b |
| Handler routing tables (method → parse handler) | ⬜ | Phase 13 — Task 88c |
| Raw `handleErrors()` AST (escape hatch) | ✅ | `errors.handle_errors` |

---

## 5. Rate limiting

| Item | Status | Source |
|------|--------|--------|
| Global rate limit (ms between requests) | ✅ | `raw.describe.rateLimit` |
| Bucket axes (IP vs UID vs order-weight) | ✅ | `rate_limits.buckets[].axes` (Task 89) |
| Bucket refill rates + sizes | ✅ | `rate_limits.buckets[].refill_per_sec` + `.max_size` (Task 89) |
| Per-endpoint cost weights against correct axis | ⬜ | Phase 14 — Task 90 |

---

## 6. WebSocket

| Item | Status | Source |
|------|--------|--------|
| WS connection URLs per stream type | 🚧 | Partial in `raw.describe.urls`; Phase 15 — Task 91 |
| Subscribe / unsubscribe message shape per channel | ✅ | `websocket.subscribe` (Task 91) — structural `mechanism`, subscribe/unsubscribe discriminant + verbs, channel-list carrier key, inherited `resolved_from`, and per-`watch*` channel templates |
| WS auth flow (sign-in message / header / query param) | ✅ | `websocket.auth` (Task 92) — structural `mechanism` (`sign_in_message` / `url_param` / `unknown` / `none`), decoded sign-in `message` (`op` / `method` discriminant + keys), `credentials`, inheritance-resolved via the `extends` chain |
| Heartbeat / ping-pong pattern | ✅ | `websocket.heartbeat` (Task 93) — structural ping strategy (`ping_kind`), decoded payload, inheritance-resolved `keep_alive_ms`, `has_pong_handler` |
| Channel → parse handler dispatch tables | ✅ | `websocket.dispatch` (Task 94) — structural channel → `handle*` entries, discriminator fields, inheritance-resolved `resolved_from`, and honest `opaque` / `none` states |
| Orderbook snapshot/delta semantics | ✅ | `websocket.orderbook_semantics` (Task 95a) — structural snapshot/delta discriminator, sequence fields, checksum hints, apply mode, inheritance-resolved `resolved_from`, and honest `unknown` / `none` states |
| Trades snapshot/delta semantics | ✅ | `websocket.trades_semantics` (Task 95b) — structural `update_model`, cache constructor, trade id dedup key, `tradesLimit` / `myTradesLimit`, private myTrades presence, and honest `unknown` / `none` states |
| OHLCV snapshot/delta semantics | ✅ | `websocket.ohlcv_semantics` (Task 95c) — structural candle update model, timeframe key, closed/confirm signal, cache limit, inheritance-resolved `resolved_from`, and honest `unknown` / `none` states |
| Reconnect triggers + backoff policy hints | ⬜ | Phase 15 — Task 96 |
| Raw WS method ASTs (escape hatch) | ✅ | `priv/discoveries/ws_methods.json` (discovery only since schema 3.0.0 / Task 117 — no longer emitted into per-exchange spec JSON; Phase 15 consumes from discoveries) |

---

## 7. Markets, currencies, fees

| Item | Status | Source |
|------|--------|--------|
| Market symbol index (per-symbol spot/swap classification) | ✅ | `markets.symbols_index` (schema 3.0.0 / Task 117 — compact `%{symbol => %{spot, swap}}`). Full market structure (price, precision, limits, info) must be fetched at runtime via live `loadMarkets()` — it drifts between extraction runs and is no longer emitted to spec. |
| Symbol format patterns per market type | ✅ | `markets.patterns` (Task 40) |
| Currency aliases (`commonCurrencies`) | 🚧 | Native id in `markets.currencies` + `raw.describe.commonCurrencies`; no dedicated derived alias map (Task 97) |
| Network info (USDT-ERC20 vs TRC20, etc.) | ✅ | `markets.currencies[<code>].networks` (Task 97) |
| Precision mode + tick/step semantics | ✅ | `markets.precision_mode` — decoded `{mode, padding_mode}` from `describe().precisionMode`/`paddingMode` (Task 98); tick/step derivation rule keyed by `mode` documented in `SCHEMA.md` § Markets |
| Trading fees (maker/taker, default) | ✅ | `raw.describe.fees.trading` |
| Tiered fee schedules + VIP level mapping | ⬜ | Phase 16 — Task 99 |
| Funding / withdrawal / deposit fees | 🚧 | Partial in `raw.describe.fees`; Phase 16 — Task 99b |
| Testnet/sandbox URL catalog | ⬜ | Phase 16 — Task 100 |
| Proxy patterns | ⬜ | Phase 16 — Task 100 |
| Timeframes map (OHLCV intervals) | ✅ | `raw.describe.timeframes` |

---

## 8. Meta / discovery

| Item | Status | Source |
|------|--------|--------|
| Exchange identity + aliases | ✅ | `exchange.*`, alias resolution (Task 44) |
| Class hierarchy + parent fallback | ✅ | `raw.class_info`, `raw.overrides_meta` |
| REST method inventory | ✅ | `raw.method_inventory` — in every per-exchange JSON. |
| WS method inventory | ➖ | Not in per-exchange JSON. Corpus-wide list lives in `priv/discoveries/methods_ws.json` since schema 3.0.0 / Task 117. Consumers needing WS dispatch read the discovery file directly. |
| Interface signatures (typed method signatures) | ✅ | `endpoints.interfaces` (Task 30) |
| Unified-method descriptors | ✅ | `endpoints.descriptors` (Task 122) — TS signature + JSDoc overlay for public unified Promise-returning methods, keyed by method name. |
| Capability flags (`has.*`) | ✅ | `raw.describe.has` |
| Base Exchange method catalog | ✅ | `_base_methods.json` (Task 31) |
| Referral URLs | ✅ | `exchange` / `raw.describe.urls.referral` |
| Certified / pro / country metadata | ✅ | `exchange` |

---

## Provenance

**Partial state (2026-04-17).** The override merge stage (Task 61b) shipped — overrides in `priv/overrides/<id>.json` apply end-to-end via `OverrideRegistry.apply_all/2`. Per-field `_provenance` tagging (Task 61a) is still ⬜; today's output has no `_provenance` map. When 61a lands (then Schema 2.0.0 via 61c), every field in this checklist will carry a `_provenance` tag in the emitted JSON: `"raw"` (direct from CCXT source/runtime), `"derived"` (computed from raw by the extractor), or `"override"` (hand-curated in `priv/overrides/`). Unprovable items already show as `null` with a reason — consumers can detect gaps without guessing.
