# Phase 1 Discoveries

Synthesized findings from all extraction tasks. This document is the design input for Phase 2 (runtime extraction) and Phase 3 (AST extraction). For raw data, see the JSON files in `priv/discoveries/`.

**Source data:** CCXT v4.x, extracted across Phase 1 sessions (2026-03-28 to 2026-03-29).

**Prerequisites:** Discovery JSON files in `priv/discoveries/` are gitignored. To regenerate, run `mix ccxt_extract.setup` then the individual extraction tasks (see Source Files table below).

---

## 1. Exchange Landscape

**Source:** `exchanges.json`, `exchange_summary.json`

### Scale

- 110 exchanges total: 107 real exchanges + 3 aliases
- 99 exchange families (most are singletons)
- 75 exchanges declare WebSocket support (`pro: true` in describe())
- 79 exchanges have WS class implementations (in `ts/src/pro/`)
- 22 are CCXT-certified

### Families

Most exchanges are standalone — only a handful form multi-member families:

| Family | Variants | Aliases | Notes |
|--------|----------|---------|-------|
| binance | binancecoinm, binanceus, binanceusdm | — | Largest family; derivatives split by margin type |
| hitbtc | bequant, fmfwio | — | White-label variants |
| okx | myokx, okxus | — | Regional variants |
| kucoin | kucoinfutures | — | Futures split to separate class |
| htx | — | huobi | Rebranded; huobi is a pure alias |
| gate | — | gateio | Rebranded; gateio is a pure alias |
| coinbase | — | coinbaseadvanced | Alias for the unified API |

**Pattern:** Variants have their own TypeScript class that extends the parent. Aliases share the parent's class — they're just a second name in the CCXT registry.

### Geography

42 countries represented. US dominates (20 exchanges), followed by CN (10), SG (9), JP (7), KR (7). 9 exchanges declare no country. The long tail is diverse — 29 countries have 1-2 exchanges each.

### API Versions

Most exchanges use v1 (37) or v2 (21). 20 exchanges have no explicit version. Version strings are inconsistent — some use "v1", others "1", one uses "v2.0.6". This is a describe() field, not standardized.

### Referrals

79 of 110 exchanges have referral URLs. CCXT discovered four referral formats during extraction: `null`, plain string URL, `{url, discount}` object, and `{url}` object without discount (hibachi pattern).

---

## 2. Class Architecture

**Source:** `class_hierarchy.json`

### Structure

- 189 total classes: 110 REST + 79 WebSocket
- Single root: `Exchange` (the base class)
- Maximum inheritance depth: 3 (Exchange → parent → variant → WS)
- Every REST exchange extends `Exchange` directly or through one intermediate class

### REST vs WS Separation

CCXT maintains strict separation between REST and WS implementations:
- REST classes live in `ts/src/*.ts`
- WS classes live in `ts/src/pro/*.ts`
- WS classes extend their REST counterpart (e.g., `ws:binance` extends `rest:binance`)
- This is a clean two-layer pattern, not an interleaved hierarchy

### Largest Base Classes

| Class | Direct Children | Role |
|-------|----------------|------|
| Exchange | 99 | Root — nearly all REST classes extend directly |
| rest:binance | 4 | 3 variants + WS counterpart |
| rest:hitbtc | 3 | 2 white-label variants + WS |
| rest:okx | 3 | 2 regional variants + WS |
| ws:binance | 3 | WS variants for binancecoinm, binanceus, binanceusdm |

### Method Counts per Class

The spread is enormous — from 1 method (minimal exchanges) to 166 (binance):

| Metric | Value |
|--------|-------|
| Min | 1 |
| Median | 38 |
| Max | 166 |

**Heaviest REST classes:** binance (166), bybit (139), kucoin (138), okx (131), gate (125), bitget (113), htx (109), hyperliquid (109).

**Implication for Phase 3:** The top 8 exchanges contain the bulk of unique method logic. These should be prioritized for AST extraction — they define the patterns that smaller exchanges inherit or simplify.

---

## 3. describe() Configuration

**Source:** `describe_keys.json`, `describe_key_analysis.json`

### Key Inventory

38 unique keys across 107 non-alias exchanges, distributed across 5 tiers:

| Tier | Count | Keys |
|------|-------|------|
| Universal (100%) | 26 | id, name, has, api, urls, fees, limits, markets, currencies, exceptions, httpExceptions, commonCurrencies, requiredCredentials, status, timeframes, rateLimit, enableRateLimit, rollingWindowSize, timeout, precisionMode, paddingMode, alias, certified, dex, pro, countries |
| Common (>90%) | 2 | features (98%), options (93%) |
| Frequent (>50%) | 1 | version (81%) |
| Uncommon (≤50%) | 2 | hostname (28%), userAgent (11%) |
| Rare (<5) | 7 | headers, comment, quoteJsonNumbers, handleContentTypeApplicationZip, orders, requiresEddsa, secret |

### Type Consistency

Most keys are type-consistent across all exchanges. Notable exceptions:

| Key | Primary Type | Exception |
|-----|-------------|-----------|
| exceptions | object (101) | undefined on 6 exchanges |
| markets | undefined (103) | object on 4 exchanges (pre-loaded markets) |
| timeframes | object (93) | undefined on 14 exchanges |
| userAgent | string (8) | undefined on 4 exchanges |

**Implication for Phase 2:** The `exceptions` key being undefined on 6 exchanges means the full describe() extractor must handle missing error mappings gracefully. The `markets` key being pre-populated on 4 exchanges is surprising — most exchanges require `loadMarkets()` to populate this.

### Nesting Depth

| Depth | Keys |
|-------|------|
| 0 (flat) | id, name, alias, certified, dex, pro, enableRateLimit, precisionMode, paddingMode, rateLimit, rollingWindowSize, timeout, version, hostname, comment, quoteJsonNumbers, handleContentTypeApplicationZip, requiresEddsa, secret |
| 1 | has, commonCurrencies, countries, httpExceptions, requiredCredentials, status, timeframes, headers, orders, userAgent |
| 2 | limits |
| 3 | exceptions |
| 4 | urls, markets |
| 5 | features, options |
| 6 | currencies, fees |
| 8 | api |

**The `api` key nests 8 levels deep** — this is the API endpoint definition tree (e.g., `api.public.get.markets`). It's the most structurally complex part of describe().

**Implication for Phase 2:** Full describe() extraction must handle arbitrary nesting. The `api` key alone requires walking up to 8 levels. A recursive JSON walker is essential — no fixed-depth approach will work.

---

## 4. Method Inventory

**Source:** `methods_rest.json`, `methods_ws.json`, `method_analysis.json`

### Scale

| | REST | WS |
|---|------|-----|
| Exchanges | 110 | 79 |
| Total methods | 5,508 | 2,434 |
| Unique method names | 703 | 377 |
| Methods per exchange (median) | 45 | 30 |
| Methods per exchange (range) | 1–166 | 1–107 |

### Method Families

Methods cluster into prefix families. The dominant families reveal CCXT's architecture:

**REST families (13 prefixes):**

| Family | Unique Methods | Role |
|--------|---------------|------|
| fetch* | 221 | Data retrieval (fetchTicker, fetchBalance, fetchOrders, ...) |
| parse* | 158 | Response normalization (parseTicker, parseOrder, parseTrade, ...) |
| other | 152 | Uncategorized (nonce, market, describe, sign, ...) |
| get* | 42 | Internal getters (getAccountId, getMarketType, ...) |
| create* | 37 | Order/entity creation (createOrder, createDepositAddress, ...) |
| handle* | 24 | Request/response handling (handleErrors, handleMarginMode, ...) |
| cancel* | 14 | Order cancellation variants |
| sign* | 13 | Authentication signing |
| set* | 11 | Configuration setters (setLeverage, setMarginMode, ...) |
| encode* | 10 | Value encoding helpers |
| edit* | 8 | Order modification |
| load* | 7 | Lazy loaders (loadMarkets, loadLeverageBrackets, ...) |
| build* | 6 | Request construction |

**WS families (13 prefixes):**

| Family | Unique Methods | Role |
|--------|---------------|------|
| handle* | 139 | Message handlers (handleTicker, handleOrderBook, ...) |
| other | 79 | Uncategorized |
| parse* | 45 | WS message parsing |
| watch* | 43 | Subscription methods (watchTicker, watchOrderBook, ...) |
| get* | 31 | Internal getters |
| fetch* | 22 | Fallback REST calls from WS context |

**Pattern:** REST is dominated by `fetch*` (read) and `parse*` (normalize). WS is dominated by `handle*` (react to messages) and `watch*` (subscribe). The two sides have complementary, non-overlapping architectures.

### Universality

Only **1 method is truly universal**: `describe` (present on 100% of both REST and WS exchanges). Everything else varies by exchange.

### Uniqueness and Rarity

- **REST:** 418 of 703 unique methods appear on only 1 exchange. 537 appear on fewer than 5.
- **WS:** 216 of 377 unique methods appear on only 1 exchange. 289 appear on fewer than 5.

**~60% of all method names are exchange-specific.** This is the long tail of CCXT — each exchange has unique endpoints, custom parsing logic, and exchange-specific helpers that no other exchange needs.

### Cross-Type Analysis

REST and WS maintain almost complete separation:

- **REST-only:** 682 method names
- **WS-only:** 356 method names
- **Shared:** only 21 method names appear in both

The 21 shared methods are: `describe`, `handleErrors`, `loadMarkets`, `transfer`, `fetchBidsAsks`, `parseTicker`, `parseTrade`, `parseBidsAsks`, `parseStatus`, `parseMarketType`, `parsePositionSide`, `parseSpotBalance`, `parseMarginBalance`, `parseTransferType`, `requestId`, `customParseBidAsk`, `customParseOrderBook`, `fromEn`, `fromEp`, `fromEr`, `fromEv`.

**Implication for Phase 3:** The shared methods are the bridge between REST and WS. When extracting method ASTs, these 21 methods need special attention — they may have different implementations in REST vs WS classes for the same exchange.

---

## 5. Surprises and Implications for Phase 2+

### Surprising Findings

1. **`describe` is the only universal method.** Even `fetchTicker`, `fetchBalance`, and `fetchOrderBook` — which feel fundamental — are not present on every exchange. Some minimal exchanges implement just a handful of methods.

2. **60% of method names are singletons.** The long tail is enormous. This means any "method pattern" approach must handle hundreds of one-off methods alongside the common patterns.

3. **4 exchanges pre-populate `markets` in describe().** Most exchanges require a `loadMarkets()` call. The 4 exceptions (with `markets: object` in describe) have static market lists.

4. **The `api` key nests 8 levels deep.** This is deeper than any other describe() key and represents the full endpoint tree. Extraction must handle arbitrary depth.

5. **6 exchanges have `undefined` exceptions.** These exchanges don't define custom error mappings in describe() — they rely entirely on the base Exchange class's error handling.

6. **`version` is only 81% present.** Not all exchanges declare an API version in describe(). Some use version as part of the URL pattern instead.

7. **WS `handle*` methods outnumber `watch*` methods 3:1.** For every subscription method, there are roughly 3 message handler methods — reflecting the complexity of message routing and parsing.

### Design Implications for Phase 2 (Runtime Extraction)

- **Full describe() extraction (Task 6)** must use recursive JSON walking — no fixed-depth approach works given the 8-level `api` key.
- **Handle `undefined` values** explicitly. At least 6 exchanges have undefined `exceptions`, 14 have undefined `timeframes`, 103 have undefined `markets`. These should be extracted as `null` in JSON, not omitted.
- **The 4 exchanges with pre-populated markets** may behave differently in `loadMarkets()` — worth checking whether they return cached data or refresh.

### Design Implications for Phase 3 (AST Extraction)

- **Prioritize the top 8 exchanges** (binance, bybit, kucoin, okx, gate, bitget, htx, hyperliquid) — they contain 50%+ of all unique method logic.
- **The 21 shared REST/WS methods** need dual extraction — both REST and WS implementations for the same exchange.
- **The long tail of singleton methods** means AST extraction must be exhaustive, not pattern-based. Extract everything; let consumers decide what matters.
- **`sign()` has 13 unique method names** in the sign* family — suggesting at least 13 distinct signing patterns exist across exchanges.

### Design Implications for Phase 4 (Output Format)

- **Per-exchange output makes sense.** The data is naturally exchange-centric — families, methods, and describe() are all per-exchange.
- **Two-layer output confirmed.** QuickBEAM data (describe, markets) and OXC data (method ASTs) are complementary and non-overlapping. The output format should keep them in separate sections.
- **Include method inventory metadata** alongside ASTs — exchange_count, family classification, and universality data help consumers prioritize.

---

## Source Files

All files live in `priv/discoveries/`, which is gitignored. None are checked into the repo — each is generated by its corresponding mix task.

| File | What It Contains | How to Generate |
|------|-----------------|-----------------|
| `exchanges.json` | Per-exchange metadata (id, name, country, pro, referral) | `mix ccxt_extract.exchanges` |
| `exchange_summary.json` | Family groupings, aggregate counts | `mix ccxt_extract.summary` |
| `class_hierarchy.json` | Full inheritance tree with per-method metadata | `mix ccxt_extract.classes` |
| `describe_keys.json` | All describe() keys + types per exchange | `mix ccxt_extract.describe_keys` |
| `describe_key_analysis.json` | Key frequency, tiers, nesting depth | `mix ccxt_extract.describe_key_analysis` |
| `methods_rest.json` | REST method inventory (params, types, statement counts) | `mix ccxt_extract.methods --type rest` |
| `methods_ws.json` | WS method inventory | `mix ccxt_extract.methods --type ws` |
| `method_analysis.json` | Family analysis, distribution, cross-type | `mix ccxt_extract.method_analysis` |
