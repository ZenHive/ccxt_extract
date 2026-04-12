# Changelog

Completed roadmap tasks. For upcoming work, see [ROADMAP.md](ROADMAP.md).

---

## [Unreleased]

### Task 57d + Task 60 (narrow precursor): Schema 1.7.1 — Fix `structure.authenticated_sections` extraction
- **Task 57d (complete)** — inheritance chain walk + else-branch inversion for `authenticated_sections` derivation
- **Task 60 (narrow precursor; generic form still ⬜)** — shipped a field-specific `priv/overrides/<exchange>.json` loader for `authenticated_sections` only. The general JSON-Pointer override contract with `value` payload, `unverified: true` flag, and SCHEMA.md documentation remains outstanding and still gates Phase 9 Tasks 61a/b/c
- Bumped schema version 1.7.0 → 1.7.1. Field shape unchanged; population fixed
- `CcxtExtract.AuthenticatedSections.derive/2` now accepts optional `api_keys` (top-level keys of `runtime.describe.api`) and handles the alternate-branch inversion pattern: `if (api === 'public') {...} else { this.checkRequiredCredentials(); ... }`. Walker flattens the else-if chain, accumulates non-auth test values across branches, and negates against `api_keys` at the final `else`
- Module header declares `# Patch count: 3/3` per CLAUDE.md Three-Strikes Derivation Rule. Future AST shapes go to `priv/overrides/`, not new walker strategies
- `CcxtExtract.Pipeline.build_exchange_data/3` now resolves inherited `sign_method` from parent classes when a subclass doesn't override `sign()` — fixes `binanceus`, `binancecoinm`, `binanceusdm`, `gateio`, `huobi`, `myokx`, `okxus`, `kucoinfutures`, `bequant`, `fmfwio`, `coinbaseadvanced`
- New `priv/overrides/<exchange>.json` mechanism. Per-file layout with `authenticated_sections`, `reason`, `verified_against`. Override lookup walks parent chain so aliases inherit (e.g. `gateio` → `gate`)
- Ships with 14 overrides covering shapes the walker cannot reach:
  - `api.startsWith('private')`: grvt
  - `api !== 'private'` inversion: toobit
  - Variable-bound routing (`const x = api[0]`, ternary, safeString): gate, coinspot, zebpay
  - sign() reassigns `api` before the gating if-chain: coinone
  - Compound array routing (`[marketType, access]`): lbank (empty — no top-level section maps to auth)
  - No `checkRequiredCredentials()` gate in sign(): paradex, hyperliquid, wavesexchange, lighter, p2b, derive, digifinex
- Before/after diff: 41 exchanges gained populated `authenticated_sections`; zero regressions (no previously-correct value was lost or shrunk). Highlights for downstream sanity-check (ccxt_client T52):
  - `null → ["private"]`: bequant, coinbaseadvanced, fmfwio, myokx, okxus, gateio; `null → ["private","v2Private"]`: huobi
  - `null → [13 sections]`: binancecoinm, binanceus, binanceusdm (AST inheritance from binance)
  - `null → ["broker","earn","futuresPrivate","private"]`: kucoinfutures (AST inheritance from kucoin)
  - `[] → ["private"]`: 24 exchanges via else-branch inversion — bit2c, bitbank, bithumb, bitstamp, btcbox, cex, coincheck, coinmate, coinspot, derive, digifinex, gate, hyperliquid, independentreserve, indodax, lighter, mercado, p2b, paradex, paymium, toobit, zebpay, + hyperliquid/paradex via override
  - `[] → ["contractPrivate","private"]`: bigone
  - `[] → ["privateEdge","privateTrading"]`: grvt
  - `[] → ["forward","private"]`: wavesexchange
  - `[] → ["ecapi","private","tlapi"]`: zaif
  - `[] → ["private","swapPrivate"]`: poloniex
  - `[] → ["private","v2Private","v2_1Private"]`: coinone
  - `["v1_01Private"] → ["private","v1_01Private"]`: zonda (chain-walk completeness)
- New integration tests in `test/ccxt_extract/authenticated_sections_integration_test.exs`:
  - Every exchange whose `describe.api` has a `/private/i` top-level key must have non-empty `authenticated_sections`. Allowlist: `lbank` (compound routing — see override)
  - Every override file must remain load-bearing: if AST derivation learns the shape, the test flags the dead override for removal
  - Every override file carries the full `authenticated_sections` / `reason` / `verified_against` schema

### Task 56b: Relocate clients back to sibling repos (supersedes Task 56)
- Moved `ccxt_client` and `ccxt_client_bak` from `clients/elixir/<name>/` back to siblings of `ccxt_extract` (`~/_DATA/code/<name>/`). Each nested `.git` travels with the `mv`, preserving history
- Reason: Claude Code walks up the filesystem and loads every `CLAUDE.md` it finds. Nested layout pulled ccxt_extract's full CLAUDE.md + all `@` imports (>100k tokens) into every client session. Sibling layout eliminates the context bleed
- Removed `clients/` tree from ccxt_extract (`clients/README.md`, `clients/rust/README.md`, `clients/elixir/README.md`) and dropped the `/clients/*/*/` `.gitignore` entry
- Updated `CLAUDE.md` § Clients, `ROADMAP.md` pipeline diagram + every `../ccxt_client/ROADMAP.md` cross-repo reference, and `examples/compare_old_*.exs` paths
- Supersedes Task 56; rust placeholder dir is dropped and will be re-created as a sibling when a Rust consumer lands

### Task 57b: Wire contract_test into `mix ccxt_extract.update`
- `mix ccxt_extract.update` now runs `mix ccxt_extract.contract_test` as non-strict Stage 6, between `validate` (Stage 5) and `analytics` (renumbered to Stage 7). Every re-extract now surfaces cross-field drift without halting the pipeline
- Stage runs for both full updates and `--skip-setup` (contract tests read emitted JSON; no QuickBEAM dependency)
- `--strict` is intentionally not forwarded — run `mix ccxt_extract.contract_test --strict` directly for CI / pre-commit enforcement
- Test override key `contract_test_task` added to the update-task Application env override mechanism

### Task 57: mix ccxt_extract.contract_test skeleton
- New `CcxtExtract.ContractTest` module runs cross-field semantic invariants over emitted `priv/output/*.json`, distinct from `validate` (which covers JSON Schema conformance + round-trip)
- New `mix ccxt_extract.contract_test` task — flags `--output DIR`, `--report PATH`, `--strict`. Writes `_contract_test_report.json` with deterministic findings order (exchange → invariant → path)
- Three seed invariants shipped, each with missing-parent tolerance so schema validation's job isn't duplicated:
  - `unified_endpoints_claimed_in_has` — every key in `structure.unified_endpoints` must have `runtime.describe.has[key]` ∈ `{true, "emulated"}`. Catches declared interface mappings for methods the exchange doesn't actually support
  - `authenticated_sections_reachable_in_api` — every `structure.authenticated_sections` entry must appear as a map key at any depth in `runtime.describe.api` (handles nested shapes like coinbase's `api.v2.private`)
  - `error_code_fields_root_in_observed_set` — per-entry root (`first(object_path)` or `object`) must be in the committed baseline at `priv/contract_test/error_code_fields_roots.json`. The baseline is updated intentionally when a new legitimate root appears; it is not derived from the same corpus being validated
- Baseline run on current corpus: 348 findings (341 unified_endpoints/has drift, 7 authenticated_sections on tokocrypto, 0 error roots). Findings are legitimate drift; follow-up tasks 57b (wire into update), 57c (triage unified_endpoints drift), 57d (fix inherited sign() derivation) track the work
- Deliberately named `--report` (not `--output`) to avoid colliding with `validate`/`update`'s existing `--output DIR` meaning

### Task 56: Establish clients/ layout
- New top-level `clients/` directory with a README documenting the nested-but-separate model (each language client is its own git repo, physically nested under `clients/<lang>/<project>/`)
- Relocated Elixir `ccxt_client` from `../ccxt_client/` → `clients/elixir/ccxt_client/` via filesystem `mv` — preserves the nested repo's `.git` and branch history intact
- Layout uses `clients/<lang>/<project>/` rather than `clients/<lang>/` so each language dir can host multiple projects and the original project name is preserved (deviation from original roadmap wording)
- `.gitignore` excludes `clients/*/*/` so nested repos stay independent from ccxt_extract's history
- Scaffolded `clients/rust/` placeholder with a README for the future Rust consumer
- Updated `examples/compare_old_specs.exs` and `examples/compare_old_counts.exs` to read from the new path
- CLAUDE.md `compare_*` example commands unchanged (already path-agnostic in the rendered form)

### Roadmap restructure: three-tier contract + parallel clients
- `ROADMAP.md` rewritten to reflect the new `CLAUDE.md` rules (three-tier raw/derived/override output, explicit consumer contract forbidding AST walking, honesty rule)
- New phases added: **Phase 8** (client harness + contract tests), **Phase 9** (override infrastructure + provenance), **Phase 10** (request signing), **Phase 11** (request building), **Phase 12** (response parsing per `parse*` type), **Phase 13** (error contract), **Phase 14** (rate-limit), **Phase 15** (WS contract), **Phase 16** (market & currency semantics)
- **Tasks 33 and 34 marked superseded** — their original deferral rationale ("consumers should classify from AST" / "derivable from existing AST") is no longer valid under the new consumer contract. Replacements live in Phase 10 and Phase 13
- Tasks 24 and 36 remain deferred (sibling-project dep / premature migration tooling)
- New `CONSUMER_CONTRACT.md` — unfiltered checklist of what a language-agnostic consumer needs, with per-item ✅/🚧/⬜ trackers linking back to tasks
- No extractor code changes in this restructure; this is documentation + planning only

### Task 55: throw_dispatches from handleErrors() AST
- New `CcxtExtract.ThrowDispatches` module — derives one entry per `this.throwExactly/BroadlyMatchedException` call in the method body
- Each entry pairs the exceptions-map source (normalized tag: `exceptions`/`exceptions.exact`/`exceptions.broad`/`by_url.exact`/`by_url.broad`/`other`) with the resolved safe* binding for arg[1], the unique resolved safe* binding referenced anywhere in arg[2], and a raw-string rendering of arg[0] as an anti-rot hatch for unrecognized shapes
- Shared AST-binding helpers now resolve simple identifier aliases (`errorInfo = message`) and wrapped message expressions (`this.id + ' ' + this.json(message)`) before deriving `throw_dispatches` or `error_code_fields`
- Schema bumped to 1.7.0 — new required `throw_dispatches` field in `HandleErrorsData`, new `ThrowDispatchEntry` type
- Binance exposes 8 dispatches with explicit `message_lookup` keys; WhiteBIT now resolves alias-backed exact lookups; Bithumb normalizes bare `this.exceptions`

### Task 54: Stabilize error_code_fields contract
- Added `object_path` field — derivation path tracing object variables back to `response` (e.g., coincatch's `firstEntry` resolves to `["response", "data", "failure", "0"]`)
- Changed `sentinel_values` from `[string]` to `[{value, operator}]` — preserves the `===`/`!==` operator for polarity detection (WhiteBIT `!== "200"` vs Binance `=== "200"`)
- Role mapping reflects CCXT helper semantics (`base/Exchange.ts:6182-6195`): `throwExactlyMatchedException` → `error_code` (exact-map lookup key via `string in exact`), `throwBroadlyMatchedException` → `error_message` (message text scanned for substrings via `string.indexOf(key) >= 0`). Fields hit by both helpers in the same handleErrors() (e.g., Alpaca's `message`) accumulate both roles naturally via list aggregation.
- Child exchanges (binanceusdm, bequant, gateio, etc.) now inherit `handle_errors` from parent when they don't override it, matching the existing pattern for describe/markets/url_templates
- Validation roundtrip checks updated with parent fallback for inherited handle_errors
- Schema bumped to 1.6.0

### Task 53: Field semantics for error_code_fields
- Extended `CcxtExtract.ErrorCodeFields` with two-pass AST analysis — pass 1 collects safe* calls with variable bindings, pass 2 scans for usage patterns to classify roles
- Added `roles` (array) and `sentinel_values` (array or null) to each `ErrorCodeFieldEntry`
- Three roles derived structurally from AST: `error_code` (variable passed to `throwExactlyMatchedException`), `error_message` (passed to `throwBroadlyMatchedException`), `status_sentinel` (compared against literals via `===`/`!==`)
- A single field can have multiple roles (e.g., Binance's `code` is both `error_code` and `status_sentinel`)
- `sentinel_values` captures the literal comparison values, sorted and stringified; null when no sentinel role
- Schema bumped to 1.5.0 — new required `roles` and `sentinel_values` fields in ErrorCodeFieldEntry
- Enables ccxt_client to use different matching logic per type instead of treating all extracted fields uniformly

### Task 52: Authenticated sections from sign() AST
- New `CcxtExtract.AuthenticatedSections` module — derives which API sections are proven to require authentication via `checkRequiredCredentials()` gates in sign() AST
- Handles three extraction patterns: direct `api === 'X'` comparisons, array-indexed `api[N] === 'X'` (coinbase/bitget/gate-style), and indirect variable bindings (e.g., `const isPrivate = api === 'private'`)
- New `structure.authenticated_sections` field in output — sorted string array or null. Placed as sibling to `sign_method` (not nested) to avoid breaking type change on existing MethodAST field
- Schema bumped to 1.4.0 — new required `authenticated_sections` field in StructureData
- Null when sign() absent; empty list when sign() exists but no `checkRequiredCredentials()` gates found. Some exchanges (lighter, p2b) authenticate without the helper — consumers needing broader auth detection should use the raw `sign_method` AST
- Replaces ccxt_client's substring matching on "private" which already had a 15-exchange bug
- **Follow-up fix**: Added array-indexed `api[N] === 'X'` pattern support after Codex review identified 12 exchanges using MemberExpression with computed access instead of plain Identifier. Tightened contract wording to "proven via checkRequiredCredentials() gates" rather than claiming complete auth coverage.

### Task 49: Error code field names from handleErrors() AST
- New `CcxtExtract.ErrorCodeFields` module — pure function that recursively walks handleErrors() AST to collect all `this.safeString/safeString2/safeValue` calls
- Added `error_code_fields` to `structure.handle_errors` in pipeline output — list of `{object, field, method, field2}` records
- Each record preserves full context: which object is accessed (response, error, data, etc.), which field name, which safe* method, and alternate field for safeString2
- Schema bumped to 1.3.0 — new required `error_code_fields` field in HandleErrorsData, new ErrorCodeFieldEntry definition
- Key design decision: all safe* calls preserved (not just `response` first-arg) — some exchanges destructure before calling safe*, consumers decide which object context matters
- Replaces ccxt_client's hardcoded 4 field names with actual per-exchange data from CCXT source

### Task 47: Round-trip validation for `url_templates`
- Added `runtime.url_templates` round-trip validation in `CcxtExtract.Validation`
- Source discovery loading now includes `url_templates.json`, and validation unwraps the inner `url_templates` map before comparison
- Alias exchanges inheriting parent URL templates are handled like `unified_endpoints`, avoiding false positives when output has inherited data but the alias has no own discovery entry

### Consumer-Requested Extractions (Phase 8 — remaining)
- ~~**Task 52**: Section visibility from sign() AST~~ — Done (see Task 52 entry above)
- **Deferred**: Rate limit headers (not observable from static analysis), endpoint weight field names (already extracted — "cost" is universal CCXT convention)

### URL Templates Extractor (Task 46)
- New QuickBEAM extractor (`CcxtExtract.UrlTemplates`) that calls `sign()` per API section to capture resolved URLs
- Reveals path prefixes injected by `sign()` not visible in `describe()` data (e.g., OKX `/api/v5/`, KuCoin `/api/v2/`, Gate `/spot/`)
- New `runtime.url_templates` field in output schema (1.2.0)
- Raw probe model: each entry records sign() inputs (`api_param`, `http_method`, `sample_path`) and output (`resolved_url`), plus derived `url_prefix`
- `url_prefix` only populated when `resolved_url` cleanly ends with `sample_path` — null for suffix-mutation exchanges (bit2c, gemini, lbank, lighter, zonda) and sign() failures
- Handles flat sections (string api param) and nested sections (array api param for Gate-style)
- Known limitation: one endpoint sampled per section — exchanges with mixed API versions within a section show the prefix for the sampled endpoint only
- Key design decision: `base_url` was removed after ~20 rounds of fixes showed it was interpretation (heuristic resolution of CCXT's inconsistent `urls.api` shapes), not extraction. `resolved_url` is the authoritative sign() output; consumers cross-reference `runtime.describe.urls.api` for base URLs
- **Canonical case for the Three-Strikes Derivation Rule** (see CLAUDE.md): 17 of those ~20 patches were sunk cost. Had the rule existed, the migration to raw-probe + `null` + override would have happened on patch #3, not patch #20. This Task is the reason the rule exists, and the reason Phase 9 override infrastructure lands before Phases 10–16

### Fix: Filter leaked helper method names from unified_endpoints
- Pipeline now cross-references `unified_endpoints` values against `interface_signatures` keys — only real HTTP endpoint methods survive
- Removed 6 leaked helper methods across grvt, hashkey, htx, huobi, kucoin, kucoinfutures (e.g., `ethGetAddressFromPrivateKey`, `parseOrderTypeTimeInForceAndPostOnly`, `tryGetSymbolFromFutureMarkets`, `utaPrivateGetPositionHistory`)
- Root cause: `interface_method_call?/1` regex matched incidental HTTP verbs in helper names; `utaPrivateGetPositionHistory` matched the real pattern but doesn't exist as an endpoint
- Validation round-trip comparison now accepts output as subset of source (pipeline filtering is intentional)
- Key decision: pipeline-level filter (authoritative cross-reference) rather than pattern-tightening (would miss `utaPrivateGetPositionHistory`)

### Task 45: Include derived analytics in `mix ccxt_extract.update`
- Added Stage 6 (Analytics) to the update orchestrator — runs after validate
- Refreshes all derived artifacts in one command: coverage, summary, family analysis, method analysis, describe keys/analysis, public exchanges, market validation
- QuickBEAM-dependent analytics (`describe_keys`, `describe_key_analysis`) skipped when `--skip-setup` is used
- Key decision: sequential execution in dependency-safe order (describe_keys before describe_key_analysis, summary before family_analysis) — all analytics are fast (seconds each)

### Task 44: Resolve alias exchange data from parent
- Alias exchanges (coinbaseadvanced, gateio, huobi) now inherit parent runtime data via class hierarchy fallback
- Pipeline `get_describe/2` and `get_markets/2` fall back to parent exchange data when own data is nil, using existing `find_parent_exchange_id/2`
- Symbol patterns auto-derive from resolved parent markets/describe
- Validation `check_describe_roundtrip` and `check_markets_roundtrip` resolve parent source data for alias round-trip comparison — no false "output has data but no source" warnings
- Key decision: reused existing unified_endpoints parent-resolution pattern rather than introducing new alias-specific logic

### Commit `priv/discoveries/` and `priv/output/` — eliminate fixture duplication
- Un-gitignored both `priv/discoveries/` and `priv/output/` — the extraction output is the primary product of this repo, now directly accessible without running Elixir
- Removed `test/fixtures/discoveries/` — cached integration tests now read from `priv/discoveries/` via `CcxtExtract.Paths.discoveries()`
- Updated 19 cached test files to use `CcxtExtract.Paths.discoveries()` instead of `Path.expand("../../fixtures/discoveries", __DIR__)`
- Updated CLAUDE.md with "Extraction Data" section documenting the single-source model

### Codex review: Unified endpoint helper leakage + update docs
- **Fix:** Added `FromAPI`/`FromRest` to helper suffixes and `@known_non_unified` set (`fetchNonce`, `fetchLatestBlockHeight`, `fetchDydxAccount`, `fetchHip3Markets`) — 5 false positives removed from contract output
- **Fix:** Clarified `--skip-setup` doc to state it skips stages 1-3 (setup + all extractors), not just setup
- Regenerated fixture; added regression tests for both suffix and name-based exclusions

### Task 42: Follow super.*() delegation in unified endpoints
- Extends the unified endpoint walker to follow `super.<method>()` calls through the base Exchange class
- Pre-loads `base/Exchange.ts` method index at extraction start; `super.*` calls look up the parent method body and collect its `this.*` calls, which resolve polymorphically back to the child class's methods — feeding into the existing delegation resolver
- **Fix:** coincatch `createOrderWithTakeProfitAndStopLoss` now resolves 5 transport endpoints (was nil — delegated via `super` to base, which calls `this.createOrder()`)
- **Fix:** kucoin `fetchDepositAddress` now includes UTA transport path (was missing — conditional `super` delegation to base, which calls `this.fetchDepositAddresses()` and `this.fetchDepositAddressesByNetwork()`)
- Adds `parent_class` field to extraction output (class name from `extends` clause)
- Scope: base Exchange class resolution only; intermediate exchange-to-exchange super calls (no known unified method cases) deferred
- Discovered via Codex code review of Task 41; includes Task 43 test coverage (7 unit tests)

### Task 41: Unified endpoint mappings
- New `CcxtExtract.UnifiedEndpoints` OXC extractor maps unified methods (`fetchTicker`, `fetchBalance`, `createOrder`, etc.) to the raw interface methods they call (`publicGetV5MarketTickers`, `privatePostV5OrderCreate`, etc.)
- Walks each unified method's AST body, finds `this.<interfaceMethod>()` CallExpressions where the method name contains an HTTP verb (Get/Post/Put/Delete/Patch)
- Multiple interface calls per unified method captured (exchanges branch by market type, account type, API version)
- Derived exchanges inherit parent mappings via class hierarchy; child overrides take precedence
- Output at `structure.unified_endpoints` — map of unified method name → sorted list of interface method names
- **Schema version bumped to 1.1.0** (additive structural field)
- Round-trip validation with content-level subset checking (not just presence); inheritance-aware (inherited endpoints don't trigger false warnings)
- **Fix:** Exclude internal helper methods (`*Request`, `*Helper`, `*Params` suffixes) from unified method detection — these are not public unified API
- **Fix:** Exclude helper function calls (`isPostOnly`, `handlePostOnly`, etc.) from interface method detection — these contain HTTP verb substrings but are not transport methods
- **Fix:** Narrow unified method detector — exclude dispatch helpers (`*FromCache`, `*Supplement`, `*Default`, `*WithMethod`, `*ById`, `*ByType`, `*ByStatus`, `*ByStates`), versioned variants (`*V1`/`*V2`/`*V3`, `*2`), and non-unified setters (`setUserAbstraction`, `setRef`, etc.) via setter whitelist. Removed 34 false positives from output.
- **Fix:** Replace fragile suffix denylist for Default dispatch helpers with regex pattern `fetchDefault[A-Z]...`. Fixes `fetchDefaultMarkets` false positive.
- **Fix (code review):** Remove overly broad `By[A-Z][a-zA-Z]+$` dispatch exclusion — it dropped legitimate public methods (`fetchOrdersByIds`, `fetchDepositAddressesByNetwork`, `fetchOrdersByState`, `fetchMarketsByTypeAndSubType`, `fetchLedgerEntriesByIds`, etc.). These are real unified API methods, not internal routers. Non-unified By* methods already fail the `has_unified_prefix?` gate; raw interface By* methods already get caught by the HTTP verb pattern.
- **Fix:** Add delegation chain resolution — when a unified method (e.g., `fetchMarkets`) delegates entirely to helper methods (e.g., `this.fetchDefaultMarkets()`) with no direct interface calls, the extractor now follows the delegation chain one level to collect the helper's interface calls. Fixes missing `fetchMarkets` mappings for bitget and htx.
- **Fix:** Merge direct and delegated interface calls — unified methods that use both direct interface calls AND helper delegation (e.g., `fetchBalance` calls `privateGetBalance` for one market type and delegates to `loadBalance` for another) now capture all paths. Previously, delegate resolution was skipped when any direct call existed, silently dropping helper-mediated endpoints.
- **Fix:** Multi-hop delegate resolution — delegation chains up to 3 hops deep are now followed (was 1). Includes cycle protection via visited-set tracking. Fixes missing mappings for exchanges with deeper helper chains (e.g., `fetchOpenOrders` → `fetchOrdersByStatus` → `fetchOrdersSinglePage` → `privateGetOrders`).

### Task 40: Symbol pattern derivation from market data
- New `CcxtExtract.SymbolPatterns` pure module derives formatting rules from `runtime.markets` — separator style, case convention, ID structure, suffixes, and anomalies per market type
- Output at `runtime.symbol_patterns` with per-type entries (`spot`, `swap`, `future`, `option`) plus `currency_aliases` from `describe().commonCurrencies`
- Computed inline during pipeline assembly (no separate discovery step, no API calls)
- Handles all exchange patterns: concatenated (Binance), dash (OKX), underscore (Gate/Deribit), lowercase (HTX), numeric/opaque (Hyperliquid), cryptonym anomalies (Kraken), suffixes (-SWAP, -PERPETUAL, M)
- 80% dominance threshold for pattern classification; anomalies tracked with IDs for consumer fallback lookup
- JSON Schema updated with `SymbolPatterns` and `SymbolPatternEntry` definitions
- **Schema version bumped to 1.0.1** (additive nullable field per SCHEMA.md contract)
- **Fixed case anomaly detection** — `detected_case` was computed but never passed to `collect_anomalies`, so minority-case IDs were invisible. Now flagged correctly.
- **Fixed dominant_value nil inflation** — `dominant_value/2` was dropping nil values before computing the 80% threshold, inflating dominance for sparse fields (e.g., 1 letter-containing ID in 284 numeric IDs = 100% "upper"). Now counts against total classifications.
- **Fixed suffix anomaly undercounting** — markets with nil suffix were excluded from suffix mismatch detection, so exchanges like paradex with `-PERP` suffix wouldn't flag suffixless swap IDs as anomalies.
- **Added round-trip validation** for `runtime.symbol_patterns` — checks presence consistency with markets (both present or both null, plus currency_aliases key check).
- **Fixed validation report hardcoded version** — `_validation_report.json` was emitting `"1.0.0"` instead of using `Schema.schema_version()`.
- **Fixed id_structure anomaly over-flagging** — `collect_anomalies` was not guarding `id_structure` on dominance, so a 50/50 split flagged all markets as anomalous.
- **All hardcoded `"1.0.0"` removed** from source and tests; all version references now use `Schema.schema_version()` or semver regex for cached fixtures.
- **Added pipeline test assertions** for `runtime.symbol_patterns` in both full and alias assembly tests

### Task 35: Extract shared modules to reduce duplication (35a + 35b)
- **`CcxtExtract.MethodAST`** — Extracted `extract_method_data/1` from 5 modules (ParseMethods, WsMethods, SignMethod, HandleErrors, Overrides) into a single shared module. All had identical implementations converting MethodDefinition AST nodes to normalized maps
- **`CcxtExtract.OXCExtractor`** — Behaviour with `__using__` macro providing default `extract/0`, `parse_file/1`, and `write!/2`. Each module implements 3 callbacks: `source_dir/0`, `extract_from_ast/2`, `write_stats/1`. Refactored 6 modules: ParseMethods, WsMethods, SignMethod, HandleErrors, InterfaceSignatures, Pagination
- **Excluded from OXCExtractor**: Methods (different API shape — `extract(:rest | :ws)`), Classes (two-directory scan), BaseMethods (single file), Overrides (delegates to Classes)
- **35c (DiscoveryLoader) deferred**: Pipeline loading code is already well-factored with generic helpers (`load_exchange_lookup/5`, `load_exchange_field/5`)
- Removed resolved TODO from HandleErrors (Task 11 TODO about shared extraction)

### Task 28: Update workflow — `mix ccxt_extract.update`
- New orchestration command chains `setup → pipeline → validate` into a single invocation
- Forwards flags to appropriate stages: `--ccxt-version`/`--latest` to setup, `--output` to pipeline+validate, `--strict` to pipeline+validate
- `--skip-setup` flag bypasses setup when sources are already current (useful for re-running pipeline+validate)
- Diff summary compares old vs new `_manifest.json`: reports CCXT version changes, exchange count delta, and lists added/removed exchanges
- **Validation reads emitted JSON from disk**: `validate_all` now reads per-exchange `*.json` files from the output directory instead of re-running the pipeline in memory. This proves the actual files consumers will read pass schema and round-trip checks. File-level integrity tracking detects missing files, corrupt JSON, orphan files, and filename/id mismatches.
- `--output DIR` on validate selects which output tree to validate (not just report location)
- Completes Phase 5 (Distribution) — ccxt_extract's output pipeline is now fully self-serve

### Task 39: Add pagination to round-trip validation
- `Validation.load_source_data/1` now loads `pagination.json` alongside the other discovery files
- New `check_pagination_roundtrip/4` compares pipeline pagination output against raw discovery data, mirroring the `build_pagination_output/1` transformation (merging `pagination_unresolved` into `_unresolved` key) for apples-to-apples comparison
- Uses `check_presence_match` + `check_data_equality` pattern — detects: output nil when source has data, source nil when output has data, and data mismatches between the two
- Pipeline test now asserts pagination output for both full and alias exchanges
- Validation test covers: matching data, data mismatch, nil-nil, source-present-output-nil, and `_unresolved` entries

### Task 26: CCXT version pinning and reproducibility
- `mix ccxt_extract.setup` now accepts `--ccxt-version VERSION` to pin a specific CCXT release (e.g., `--ccxt-version 4.5.45`). Updates both npm bundle and TS source (git tag checkout). Verifies installed version matches after npm install
- `--latest` flag updates both npm bundle (`npm.update`) and TS source (`git pull`) to newest version, handling detached HEAD recovery from prior tag checkouts
- `_manifest.json` now includes `source_git_sha` for full reproducibility traceability — consumers can verify both the npm package version and the exact source commit
- Manifest `ccxt_version` derived from exchange data (source of truth), with `source_git_sha` enriched from version file

### Task 26 fix: Error enforcement and git directory detection
- **Version-sensitive flags now fail on error**: `--latest` and `--ccxt-version` raise `Mix.Error` when git operations fail or npm/TS versions mismatch (was: silent warning with "Setup complete"). No-flag path keeps warn-only behavior
- **Git worktree/submodule support**: `resolve_ccxt_dir/0` now detects `.git` as both directory (normal repo) and file (worktree/submodule `gitdir:` pointer)
- **Relative symlink resolution**: symlink targets are now resolved against the link's parent directory, not used as-is
- **Hermetic integration tests**: setup tests save and restore git HEAD, npm package.json, priv bundle, and version file in on_exit — tests no longer leave the environment at a different CCXT version
- **Setup instructions updated**: sparse checkout instructions now include `package.json` (required by `--latest`/`--ccxt-version` for version verification). Updated in setup task, CLAUDE.md, and error messages

### Task 38: Pagination data quality fixes
- **Branch-dependent duplicates preserved**: Pagination entries that target the same method name from different code paths are now all kept as arrays. Previously `Map.put_new` silently dropped variants (e.g. coinbase fetchAccounts V2/V3 had different cursor configs but only one survived)
- **Variable method names captured**: Pagination calls with runtime-computed method names (e.g. bydfi `fetchTransactionsHelper` passes `methodName` variable) are now emitted as unresolved entries with `target_method: null` in a separate `pagination_unresolved` list, instead of being silently dropped
- **Provenance tracking**: Every PaginationEntry now includes `containing_method` (which method body the call was found in) and `target_method` (the method name passed to `fetchPaginatedCall*`, nullable for unresolved)
- **Schema change**: `pagination` value changed from `PaginationEntry` to `[PaginationEntry]` (always arrays). Optional `_unresolved` key in pipeline output for variable method names. `PaginationEntry` now requires `containing_method` and `target_method` fields
- Extraction count: 193 entries (up from 188 — 5 previously-deduplicated variants recovered), 1 unresolved entry

### Task 32: Pagination strategy extraction
- New `CcxtExtract.Pagination` module extracts pagination strategies from exchange TS source files using a recursive AST walker
- Four strategies extracted: dynamic, deterministic, cursor, incremental — with strategy-specific parameters (cursor_received, cursor_sent, page_key, max_entries_per_request)
- Recursive walker finds `this.fetchPaginatedCall*` calls nested inside method bodies (unlike existing extractors that only inspect top-level class members)
- Pipeline integration: `pagination` added to structure section as nullable map of method name -> [PaginationEntry]
- `PaginationEntry` definition added to JSON Schema with strategy enum and nullable strategy-specific fields
- `mix ccxt_extract.pagination` Mix task for standalone extraction
- Third Go extractor parity item completed (Phase 6)

### Task 31: Base normalizer methods from Exchange.ts
- New `CcxtExtract.BaseMethods` module extracts `parse*()` and `safe*()` members from the base `Exchange.ts` class — both MethodDefinition (full signatures) and PropertyDefinition (class field aliases to imported utilities)
- Each entry includes name, category (parse/safe), params with types, return type, async flag, and `source` field (`"method_definition"` or `"field_assignment"`)
- Global artifact `_base_methods.json` stored once (not per-exchange) — shared by all exchanges
- Pipeline integration: copies `_base_methods.json` to output directory using `discoveries_dir` option (not hardcoded path)
- `mix ccxt_extract.base_methods` Mix task for standalone extraction
- Code review fixes: made `extract_method_data` private, threaded `discoveries_dir` through `write!/3`, removed dead `load_base_methods` from pipeline data map, documented raise behavior

### Task 27: Schema versioning contract
- Created `SCHEMA.md` documenting the semver contract for the `schema_version` field in all output JSON
- Defines patch/minor/major version bump rules: additive fields (patch), structural changes with aliases (minor), breaking changes (major)
- Consumer guidance with fail-fast code examples for Python, Rust, and Elixir
- Documents v1.0 guarantees: two-layer model (runtime + structure), two-state optionality, all current fields and type definitions
- Version history table for tracking schema evolution
- Updated `CcxtExtract.Schema` moduledoc to reference `SCHEMA.md` for the full contract

### Task 30: Interface signatures from abstract/*.ts
- New `CcxtExtract.InterfaceSignatures` module extracts typed API method signatures from `priv/ccxt/ts/src/abstract/*.ts` — per-exchange interface declarations generated by CCXT
- Each signature contains name, params (with types), and return type — no method body (simpler than MethodAST)
- New `InterfaceSignature` $def in JSON Schema — distinct from MethodAST (no async/statements/body)
- Pipeline integration: `interface_signatures` added to structure section, loaded via `load_exchange_lookup`, validated via new `check_nullable_interface_signature_map`
- `mix ccxt_extract.interface_signatures` Mix task for standalone extraction
- First Go extractor parity item completed (Phase 6)

### Task 30 fix: Alias exchange support + round-trip validation
- Fixed extractor to accept any `TSInterfaceDeclaration`, not just `interface Exchange` — alias exchanges (binanceus, gateio, huobi, etc.) use parent interface names (`interface binance`, `interface gate`, `interface htx`)
- Now extracts all 110 abstract exchange files (was 99 — 11 alias exchanges were silently skipped)
- Added `interface_name` field to extraction output — captures the actual TS interface name per exchange
- Wired up round-trip validation for `interface_signatures` in `Validation.validate_roundtrip/3` — reuses existing `check_method_map/5` helper
- Strengthened tests: assert zero skipped files, test alias interface extraction, test corrupted/missing signature detection

### Task 25: Configurable output directory
- Completed the distribution output contract for `mix ccxt_extract.pipeline --output <path>`
- `CcxtExtract.Pipeline.write!/2` now copies `priv/schema/exchange_v1.json` into the target directory as `exchange_v1.json`
- Output directories now contain the full consumer artifact set: per-exchange JSON files, `_manifest.json`, and `exchange_v1.json`
- Preserved the existing automatic stale-file cleanup for exchange JSON files when rewriting a target directory
- Added regression coverage for schema copy, stale exchange cleanup, and cached fixture-backed custom output writes

### Audit 5: Pipeline assembly and nullability semantics
- No confirmed real-artifact nullability defects were found in the tracked cached fixture set for this scope
- Clarified legitimate `null` cases with cached regression coverage for alias layers, non-pro WS layers, root-exchange overrides, empty `parse_methods`, and source entries that explicitly report `handle_errors: null`
- Hardened `CcxtExtract.Pipeline` to validate malformed global discovery entries in `methods_rest.json`, `methods_ws.json`, `handle_errors.json`, `parse_methods.json`, and `ws_methods.json` before indexing them
- Malformed global discovery entries now surface under `corrupt_entries` instead of silently collapsing into expected-looking `null` output
- Deepened `Schema.validate/1` so pipeline assembly now rejects partial `class_info`, `methods`, and `handle_errors` maps instead of treating any map-shaped value as valid
- Added regression tests for corrupt global discovery entries and WS-only partial-structure cases, plus cached integration tests that document real fixture-backed nullability reasons

### Audit 1: Manifest and artifact integrity
- No confirmed manifest/artifact integrity defects were found in the tracked cached fixture set for this scope
- Hardened `CcxtExtract.Pipeline` to surface `orphan_entries` and `id_mismatch_entries` alongside existing `missing_entries` and `corrupt_entries`
- `describe/*.json` now validates both top-level `id` and nested `describe.id` against the manifest/filename expectation; `load_markets/*.json` now validates top-level `id`
- Added orphan detection for unreferenced per-exchange files in `describe/` and `load_markets/`, plus orphan-id detection for global discovery files whose entries are not present in `exchanges.json`
- Validation reports and Mix tasks now print all four integrity buckets separately
- Added regression tests for injected bad-artifact scenarios and cached baseline assertions that the checked-in fixtures remain clean

### Comparison script — ccxt_extract vs ccxt_go_extractor
- `examples/compare_go_extractor.exs` compares structural AST data between the TS-based ccxt_extract and the Go-based ccxt_go_extractor across 110 overlapping exchanges
- Runs Go extractor's `profile` command live via `System.cmd` for each exchange
- **Key findings**: 98.1% parse method name overlap; Go has 14,181 endpoint stubs vs 8,896 API paths (Go generates per-endpoint functions); WS overlap is 37.3% because TS includes `handle*` internal handlers while Go tracks those separately in `handlers.assembly`
- Each extractor has unique data: Go provides handler routing, auth assembly, pagination, base normalizers, interface signatures; ccxt_extract provides runtime describe, has flags, markets, overrides

### Task 29: Comparison script — ccxt_extract vs old ccxt_client specs
- `examples/compare_old_specs.exs` compares new JSON output against old `.exs` specs from `../ccxt_client/priv/specs/extracted/`
- Classifies each old spec key as **covered** (equivalent in new output), **richer** (new has more detail), **consumer-specific** (computed by ccxt_ex, not from CCXT), or **unknown** (not in any category)
- Spot-checks covered keys with exact match, key-subset, or presence checks; uses fuzzy normalization to handle camelCase↔snake_case and acronym splitting differences
- **Result**: 100% coverage across 104 overlapping exchanges — zero unknown keys, all old keys accounted for
- Remaining spot-check failures are expected: `urls` has 3 ccxt_ex-added keys (`api_sections`, `other`, `sandbox`); `has` has 2 keys removed between CCXT 4.5.42→4.5.45 (`watchMarkPrice`, `watchMarkPrices`)
- 38 exchanges missing `ws` structure data (exchanges without WebSocket support)

### Task 23: Resolve `__function:` sentinels in describe data
- **Problem**: The minified CCXT browser bundle mangled error class names — `__function:ExchangeError` appeared as `__function:h`, losing the mapping from error codes to CCXT error classes across all 107 exchanges
- **Solution**: Build an `_errorNameMap` at runtime by instantiating each Error subclass on the `ccxt` global and reading the `this.name` instance property (set explicitly in CCXT constructors as string literals, which minification cannot mangle)
- **Result**: All 34 distinct `__function:` sentinel values now carry real class names (e.g. `__function:AuthenticationError`, `__function:RateLimitExceeded`)
- Applied to both `describe.ex` and `load_markets.ex` (each has its own `prepare()` function and QuickBEAM runtime)
- `__undefined` sentinels unchanged — they correctly represent JS `undefined` values
- Key insight: `Function.name` (static property) is mangled by minifiers, but `this.name = 'ExchangeError'` (instance property set in constructor) survives because string literals are never mangled
- Updated `exchange_v1.json` schema description to document resolved sentinel format

### Task 16: Full Validation
- `CcxtExtract.Validation` — two-layer validation module: JSON Schema conformance (draft 2020-12 via JSV) and round-trip comparison against source discovery data
- `mix ccxt_extract.validate` — CLI task with `--strict` (CI mode) and `--schema-only` flags; writes report via `Paths.priv("output/_validation_report.json")` (resolves under `_build/` in dev, `priv/` in releases)
- **JSON Schema layer**: compiles `exchange_v1.json` via JSV, validates all 110 exchanges against full type/property constraints; catches scalar types, additionalProperties violations, missing required fields
- **Round-trip layer**: compares pipeline output against source fixture data for 11 reference exchanges (tier 1 + tier 2 + DEX); checks describe key sets, full market data (count + symbol sets + per-market equality), class info (REST + WS method counts), method inventories (REST + WS name sets + per-method signature equality), sign_method/handleErrors/parse/ws full MethodAST equality, handleErrors exception + http_exception map equality, override extends chains (REST + WS)
- **Schema corrections found during validation**: `ClassEntry` updated to include `id`, `type`, `extends_raw`, `extends_resolved` (was missing from Task 14 design); `HandleErrorsData.exceptions` changed to `additionalProperties: true` (CCXT uses market-type-specific keys like `spot`, `inverse`, `linear` beyond `broad`/`exact`)
- **Pipeline stats surfaced**: validation report includes `pipeline_stats` (missing_entries, corrupt_entries, validation_errors) from Pipeline.extract — `--strict` mode now fails on data gaps, not just schema/roundtrip errors
- Key decision: `Schema.validate/1` (fast structural check) stays for pipeline assembly; `Validation.validate_schema/2` (full JSV enforcement) is the thorough check for CI/reporting
- Completes Phase 4 (Output Format & Validation)

### Fix: Validation edge cases (second review)
- **Corrupt per-exchange JSON no longer crashes validation**: `read_describe_entry/2` and `read_markets_entry/2` now rescue `Jason.DecodeError` with a Logger warning instead of raising — corrupt files produce nil entries handled downstream, not pipeline crashes
- **WS class_info nil gap**: `check_class_entry/5` now detects when `output.class_info.ws` is nil but source has a WS class entry. Previously the nil guard clause silently passed
- **WS-only overrides extends check**: `maybe_check_overrides_extends/4` now uses `source_rest || source_ws` as the primary source for the extends comparison, so WS-only overrides with wrong extends are caught

### Fix: Deepen round-trip validation from shape-only to full data comparison
- **Markets**: now compares symbol sets and full per-market data equality, not just `market_count`. Dropped/corrupted markets are caught.
- **sign_method**: now compares full MethodAST equality, not just presence/absence. Corrupted ASTs are caught.
- **handle_errors**: now compares method AST + exceptions map + http_exceptions map equality. Wrong exception mappings are caught.
- **Methods inventory (REST/WS)**: now compares full signature equality per method, not just name sets. Changed async/params/return_type are caught.
- **parse_methods/ws_methods**: now compares full MethodAST equality per method, not just key sets. Corrupted method bodies are caught.
- **Output path docs**: clarified that `Paths.priv()` resolves under `_build/` in dev (standard `:code.priv_dir()` behavior)

### Fix: Validation correctness (post-review)
- **WS-side round-trip gaps**: Round-trip validator now checks both REST and WS sides for class_info (method_count), method inventory (name sets), and overrides (parent_key/extends). Previously only REST was validated, so WS-side mismatches went undetected
- **JSV error extraction**: Fixed `extract_jsv_errors` to match JSV's actual normalized error shape (atom keys, `%{details: [error_unit]}` with `instanceLocation`/`errors` nesting). Previously all schema failures collapsed into a single opaque blob at path "/" due to string/atom key mismatch and wrong top-level key name
- **Pipeline stats in report**: `validate_all/1` now captures pipeline stats (missing_entries, corrupt_entries) instead of discarding them. Mix task surfaces data gaps and `--strict` mode fails on incomplete artifact sets

### Fix: Schema contract for overrides + error classification
- Updated `OverridesData` in `exchange_v1.json` to match the actual REST/WS grouped output shape (`extends`/`rest`/`ws`), added `OverrideEntry` definition for the nested structure
- Strengthened `Schema.validate/1` override validation: checks `extends`/`rest`/`ws` required keys and validates nested `OverrideEntry` shape (parent_key, overridden, new_methods, inherited)
- Fixed error classification collapse: `read_markets_entry` and all global file loaders no longer use `{:error, _}` wildcards — corrupt JSON (`{:error, {:invalid_json, ...}}`) is now distinguished from missing files
- Corrupt global discovery files (class_hierarchy, overrides, manifests) now raise immediately instead of silently becoming "missing"
- Corrupt per-exchange files tracked separately in `stats.corrupt_entries` — surfaced in mix task output and `--strict` exit code
- Key decision: global file corruption is a hard error (broken artifact set), per-exchange corruption is tracked and reported (pipeline continues for other exchanges)

### Bugfix: Track missing per-exchange discovery files
- Fixed silent data loss where `read_describe_entry/2` and `read_markets_entry/2` returned `{id, nil}` when per-exchange files were missing, making the nil indistinguishable from alias exchanges with legitimately absent data
- Added `missing_entries` accumulator to `load_all_data` — separate from `missing_files` (which raises on missing manifests). Per-exchange gaps are tracked in `stats.missing_entries` without crashing partial pipeline runs
- Added `--strict` flag to `mix ccxt_extract.pipeline` — fails with non-zero exit when validation errors or missing per-exchange files exist (for CI use)
- Key decision: two separate lists because manifest-level missing (`missing_files`) is an infrastructure failure (hard raise), while per-exchange missing (`missing_entries`) is a data gap (tracked, non-fatal)

### Task 15: Full Extraction Pipeline
- `CcxtExtract.Pipeline` — reads all discovery data from `priv/discoveries/`, assembles per-exchange JSON conforming to `exchange_v1.json` schema, validates each with `Schema.validate/1`
- `mix ccxt_extract.pipeline` — single command produces `priv/output/<exchange_id>.json` for all 110 exchanges plus `_manifest.json`
- **Data mapping**: translates extraction output format to schema format — handle_errors `handle_errors` → `method`, overrides `overrides` → `overridden` / `inherited_methods` → `inherited`, class_hierarchy grouped into `rest`/`ws` structure
- **Deterministic output**: sorted by exchange id, single timestamp for all exchanges, ccxt_version read from `priv/ccxt_version.json`
- Stale file cleanup: removes orphan JSON files from output directory before writing
- All 110 exchanges pass schema validation with zero errors
- Key decision: pipeline reads existing extraction outputs (fast, ~10s) rather than re-running extractors — individual extractors already handle their own extraction and write to `priv/discoveries/`

### Task 14: Output Schema Design
- `priv/schema/exchange_v1.json` — formal JSON Schema (draft 2020-12) defining the per-exchange output format
- `CcxtExtract.Schema` — pure Elixir module: `build_exchange/4` assembles per-exchange output from extraction layers, `validate/1` checks structural conformance
- **Two-layer model**: `runtime` (QuickBEAM values: describe, markets) and `structure` (OXC AST: class hierarchy, method signatures, method bodies, overrides)
- **Two-state optionality**: present-with-data (map/list) or `null` (missing/not applicable) — all keys always materialized, consumers check for null
- **Unified MethodAST shape**: `{async, params, return_type, statements, body}` used consistently across sign, handleErrors, parse*, ws*, and override methods
- Reusable `$defs` for MethodAST, MethodParam, MethodSignature, ASTNode, ClassEntry, HandleErrorsData, OverridesData
- Structural validation catches: missing required keys, wrong schema version, non-map sections, malformed MethodAST (missing body/params/etc), invalid method maps. Full JSON Schema enforcement (typed scalars, additionalProperties) deferred to Task 16
- Key decision: AST nodes use `additionalProperties: true` (ESTree nodes are too varied to enumerate); envelope sections use `additionalProperties: false` for strictness
- Second Phase 4 (Output Format & Validation) task — defines the target format for the extraction pipeline (Task 15)

### Task 17: Coverage Report
- `CcxtExtract.CoverageReport` — pure analysis module reading all extraction outputs, reporting per-exchange coverage across 10 data layers
- `mix ccxt_extract.coverage` — CLI task producing `priv/discoveries/coverage_report.json` with console summary
- Ten coverage layers: describe, load_markets, class_hierarchy, methods_rest, methods_ws, sign_method, handle_errors, parse_methods, ws_methods, overrides
- Per-exchange adaptive scoring: layers that don't apply (overrides for root exchanges, most layers for aliases) are excluded from the max rather than counted as gaps
- WS layers are data-driven: applicable if exchange has WS data in discovery outputs OR is marked `pro`, not purely pro-gated
- ws_methods uses count-based checking (matching parse_methods pattern) — exchanges with ws_method_count: 0 correctly show as gaps
- Key finding: derived exchanges (binanceus, kucoinfutures, etc.) correctly show "no_sign_method" / "no_handle_errors" — they inherit these from their parent, which is expected CCXT architecture, not a gap in extraction
- Key finding: load_markets has lowest coverage in priv/discoveries/ (only dydx cached locally); full extraction results are in test fixtures
- First Phase 4 (Output Format & Validation) task — informs schema design (Task 14) by revealing what data exists per exchange

### Task 13: Class Hierarchy and Overrides
- `CcxtExtract.Overrides` — for each exchange extending another, identifies overridden methods (with full AST body), new methods (with full AST body), and inherited methods (names only)
- `mix ccxt_extract.overrides` — CLI task producing `priv/discoveries/overrides.json`
- Two-phase extraction: uses `Classes.extract/0` for hierarchy data, then re-parses only derived class TS files for method bodies
- Memoized ancestor method accumulation walks inheritance chains to compute override/new/inherited sets via MapSet operations
- 90 derived exchanges analyzed — all 90 override `describe()` (universal override); 100 total overrides, 2352 new methods
- REST variants (binanceus, binancecoinm, etc.) typically override only `describe` with configuration changes
- WS exchanges add many new methods (watch*/handle*) on top of their REST parent's inherited methods
- Key finding: `describe()` is the only universally overridden method — confirms Phase 1 discovery that exchanges differ primarily in configuration, not implementation
- Completes Phase 3 (Structural Extraction) — all five AST extraction tasks done, unblocking Phase 4 (Output Format & Validation)

### Task 12: WS Method AST Extraction
- `CcxtExtract.WsMethods` — extracts all `watch*()` and `handle*()` method bodies as raw ESTree AST for every WS exchange via OXC
- `mix ccxt_extract.ws_methods` — CLI task producing `priv/discoveries/ws_methods.json`
- Scans `pro/*.ts` (WS exchange files) — 79 exchanges found, 69 with WS methods, 1574 total methods extracted
- Combined output: watch* and handle* methods in a single `ws_methods` map keyed by method name; consumers filter by async flag or name prefix
- Watch methods are async (WS subscriptions); handle methods are almost universally sync (message processing), with rare exceptions (e.g., `bitget.handleCheckSumError`)
- Follows ParseMethods (Task 11) pattern: map-keyed multi-method extraction with `ws_method_count` for quick scanning
- Reuses `Methods.extract_params/1` and `Methods.extract_return_type/1` — same shared helpers as Tasks 9-11
- Fourth Phase 3 (Structural Extraction) task — completes WS structural coverage alongside REST extraction from Tasks 9-11

### Task 11: parse*() Method AST Extraction
- `CcxtExtract.ParseMethods` — extracts all `parse*()` method bodies as raw ESTree AST for every REST exchange via OXC
- `mix ccxt_extract.parse_methods` — CLI task producing `priv/discoveries/parse_methods.json`
- Key structural difference from Tasks 9/10: extracts ALL methods matching the `parse*` prefix per exchange (not a single named method), outputting a map keyed by method name
- Per-exchange output includes `parse_method_count` for quick scanning; exchanges with no parse methods get an empty map
- Envelope includes `total_methods` count across all exchanges and `with_parse_methods` count
- Reuses `Methods.extract_params/1` and `Methods.extract_return_type/1` — same shared helpers as Tasks 9 and 10
- Key finding: all parse methods are synchronous; typical signature is `(data: Dict, market: Market = undefined)` with typed return values (Ticker, Order, Trade, etc.)
- Third Phase 3 (Structural Extraction) task — completes parse method coverage for REST exchanges

### Task 10: handleErrors() Method AST Extraction
- `CcxtExtract.HandleErrors` — extracts the `handleErrors()` method body as raw ESTree AST for every REST exchange via OXC
- `mix ccxt_extract.handle_errors` — CLI task producing `priv/discoveries/handle_errors.json`
- Scans all REST exchanges — those without handleErrors() included with `"handle_errors": null`
- **First extractor combining both data sources**: merges OXC AST (method body) with QuickBEAM data (describe exceptions)
- Per-exchange output includes `exceptions` (exact/broad error string → error class) and `http_exceptions` (HTTP status → error class) from describe() JSON
- Exchanges without describe files (aliases not extracted in Task 6) get `null` for exception fields
- Non-map sentinel values (`__undefined` from QuickBEAM) normalized to `null` at extraction boundary
- Reuses `Methods.extract_params/1` and `Methods.extract_return_type/1` — same shared helpers as Task 9
- Key finding: all handleErrors() methods are synchronous; typical signature has 9 parameters (code, reason, url, method, headers, body, response, requestHeaders, requestBody)

### Task 9: sign() Method AST Extraction
- `CcxtExtract.SignMethod` — extracts the `sign()` method body as raw ESTree AST for every REST exchange via OXC
- `mix ccxt_extract.sign_methods` — CLI task producing `priv/discoveries/sign_methods.json`
- 110 exchanges scanned, 99 with sign() method — exchanges without sign() included with `"sign": null`
- Output preserves the complete method AST: parameters (with TS type annotations), return type, async flag, statement count, and the full body as raw ESTree JSON
- Reuses `Methods.extract_params/1` and `Methods.extract_return_type/1` for parameter/type extraction — avoids duplication
- Body AST includes byte offsets (`start`/`end`), all node fields — consumers get the raw AST as OXC produces it
- Key finding: all sign() methods are synchronous; standard signature is `(path, api, method, params, headers, body)` with minor naming variants
- First Phase 3 (Structural Extraction) task — establishes the pattern for Tasks 10-12

### Hardening: Error Paths, Test Serialization, and Missing-File Guards
- **Market validation**: pre-flight check for missing exchange files before `File.read!` — returns `{:error, {:missing_input, path}}` instead of crashing
- **Family analysis**: explicit error handling in `diff_describe_for_pair/3` — logs warning for missing root describe files (corrupted upstream), silently skips missing member files (expected for aliases)
- **Mix tasks**: `describe_key_analysis`, `family_analysis`, `method_analysis` switch `Mix.shell().error` → `Mix.raise` for missing input — consistent with all other tasks, sets non-zero exit code
- **Integration tests**: all 7 tests using `run_task_capturing_output` set `async: false` — prevents flaky failures from concurrent `Mix.shell` mutation
- **Task helpers**: `collect_shell_output/1` now captures `:error` messages alongside `:info`
- **New tests**: file-level validation tests for `MarketValidation.validate/1` (missing manifest, missing exchange file, happy path) and Mix task error-path tests for `describe_key_analysis`, `family_analysis`, `method_analysis`

### Task 7: Exchange Family Analysis
- `CcxtExtract.FamilyAnalysis` — pure analysis module reading existing discovery JSON (class hierarchy, exchange summary, per-exchange describe)
- `mix ccxt_extract.family_analysis` — CLI task producing `priv/discoveries/family_analysis.json`
- Groups exchanges into multi-member families (binance, hitbtc, okx, kucoin, coinbase, gate, htx) and standalone families
- Per-variant analysis: own methods from OXC class data, top-level describe() key diffs from QuickBEAM data
- Key finding: `describe()` is the only universally overridden method — variants mostly differ in configuration (id, name, urls, has, options), not implementation
- Aliases without describe files (skipped in Task 6) get empty describe diffs — correctly handled
- Completes Phase 2 (Runtime Extraction)

### Task 8c: Market Data Validation
- `CcxtExtract.MarketValidation` — two-layer validation of extracted loadMarkets() data
- **Layer 1 (structural)**: offline validation of cached JSON — required field presence, boolean/map type checks, type↔flag consistency, undefined density reporting
- **Layer 2 (spot-check)**: re-extracts a sample of exchanges via `LoadMarkets.extract/1`, compares market counts and symbol sets against cached data
- Findings use severity levels: **error** (extraction bug), **warning** (CCXT data quirk), **info** (density stats)
- `mix ccxt_extract.validate_markets` — CLI task with `--spot-check` and `--exchanges` options
- Output: `priv/discoveries/market_validation.json` with per-exchange reports and summary
- Full extraction run: 100 exchanges succeeded (7 failed — auth/geo-blocked), 89k+ markets validated, zero structural errors
- Updated `test/fixtures/discoveries/load_markets/` with full extraction data (was dydx-only)
- Fixed pre-existing `load_markets_cached_test.exs` to handle exchanges with zero markets (coincatch)
- Key decision: type↔flag mismatches are warnings not errors — CCXT has known inconsistencies on delisted markets

### Task 22: Split Integration Tests into Cached/Extraction Tiers
- Two-tier test architecture: **cached tests** (read tracked fixtures, run by default) and **extraction tests** (boot QuickBEAM/OXC, tagged `:extraction`, excluded by default)
- `ExUnit.configure(exclude: [:extraction])` in `test_helper.exs` — default `mix test.json` completes in ~0.4s instead of minutes
- Cached test fixtures tracked at `test/fixtures/discoveries/` — portable across clean checkouts and CI (no dependency on gitignored `priv/discoveries/`)
- Pure `write!/1` serializer tests (exchanges, classes) moved from integration modules to unit test files — avoids triggering expensive `setup_all` extraction in the fast tier. Other integration write tests (describe, describe_keys, summary, load_markets) depend on `setup_all` extraction data and correctly remain in the extraction tier; unit-level write tests with synthetic data already exist for describe_keys and describe_key_analysis
- Extraction tests tagged with `@moduletag :extraction`; cached and unit tests left untagged
- Run `--include extraction` for full suite, `--only extraction` for extraction tests alone
- Fast tier: 432 tests in ~0.4s. Extraction tier: 243 tests in ~89s

### Task 8b: Rate-Limited loadMarkets() Extraction
- `CcxtExtract.LoadMarkets` — calls `loadMarkets()` on all non-alias exchanges via QuickBEAM, real HTTP requests to exchange APIs
- `mix ccxt_extract.load_markets` — CLI task with `--delay`, `--concurrency`, and `--exchanges` options
- Parallel extraction via `Task.async_stream`: configurable concurrent QuickBEAM runtimes, each with 1GB memory limit
- Per-exchange output to `priv/discoveries/load_markets/<exchange_id>.json` with manifest at `_manifest.json`
- Most exchanges succeed without authentication — loadMarkets() is effectively public on nearly all exchanges
- Permanent failures recorded in manifest with error messages; known categories documented in test module (auth-required, suspended, geo-blocked/WAF)
- Key design: batched runtime approach solved QuickBEAM OOM — sequential extraction hit default heap limit; parallel runtimes with generous memory handle the full set
- `QuickbeamRuntime.start/1` now accepts `:memory_limit` option (backwards-compatible)
- Function and undefined sentinels preserved via the `prepare()` pattern from Task 6

### Task 8a: Classify Exchange Credential Requirements
- `CcxtExtract.PublicExchanges` — reads per-exchange describe() JSON files, classifies by credential requirements
- `mix ccxt_extract.public_exchanges` — CLI task that runs analysis and writes `priv/discoveries/public_exchanges.json`
- All 107 exchanges advertise `fetchMarkets` capability (`has.fetchMarkets == true` is universal)
- 13 distinct credential patterns identified — dominant pattern is `["apiKey", "secret"]` (78 exchanges)
- Only 1 fully public exchange (dydx requires zero credentials); DEX exchanges use `privateKey`/`walletAddress` patterns
- Pure analysis module — no QuickBEAM needed, reads existing Task 6 output
- Fails loudly if any manifest-listed describe file is missing (no silent fallback to empty data)
- Note: "advertises fetchMarkets" ≠ "loadMarkets() works without auth" — actual callability verified in Task 8b

### Task 6: Full describe() Extraction
- `CcxtExtract.Describe` — extracts the complete `describe()` for all 107 non-alias exchanges via QuickBEAM
- `mix ccxt_extract.describe` — CLI task that runs extraction and writes per-exchange JSON files
- Per-exchange output to `priv/discoveries/describe/<exchange_id>.json` with manifest at `_manifest.json`
- Function sentinel handling: JS function references (error classes, parseNumber, etc.) serialized as `__function:<name>` strings
- Undefined sentinel handling: JS `undefined` values (silently dropped by JSON.stringify) preserved as `__undefined` strings
- Extracts one exchange at a time via Elixir loop to keep memory bounded (not one massive JSON string)
- 107 exchanges extracted in ~5 seconds with progress logging every 20 exchanges
- Key finding: binance has 930 function references and 127 undefined values in its describe() — the sentinels capture data that naive JSON.stringify would lose

### Task 21: Extract Shared Test Helpers
- Created `test/support/task_helpers.ex` with `CcxtExtract.TaskHelpers` module
- Extracted `run_task_capturing_output/2` and `collect_shell_output/1` from 4 integration test files
- All test files now `import CcxtExtract.TaskHelpers` instead of defining private duplicates

### Task 5: Document Discoveries
- `DISCOVERIES.md` — synthesized findings from all 8 discovery JSON files into a structured design document
- Five sections: Exchange Landscape, Class Architecture, describe() Configuration, Method Inventory, Surprises & Implications
- Key findings documented: `describe` is the only universal method, 60% of method names are exchange-specific singletons, `api` key nests 8 levels deep, REST/WS maintain near-complete separation (only 21 shared method names)
- Design implications captured for Phase 2 (recursive JSON walking, undefined handling), Phase 3 (top-8 exchange prioritization, dual REST/WS extraction for shared methods), and Phase 4 (per-exchange two-layer output)
- Completes Phase 1 (Setup & Discovery)

### Task 4c: Method Family Analysis
- `CcxtExtract.MethodAnalysis` — reads methods_rest.json + methods_ws.json, produces family analysis with pure functions separate from I/O
- `mix ccxt_extract.method_analysis` — CLI task that runs analysis and writes `priv/discoveries/method_analysis.json`
- Prefix family grouping: extracts camelCase prefix (`fetch*`, `parse*`, `create*`, `cancel*`, `watch*`, `handle*`, `sign`, etc.) with 13 known CCXT prefixes; unrecognized prefixes go to "other"
- Per-family output: method count, per-method exchange count and percentage, sorted by popularity
- Universality detection: methods present on 100% of exchanges (e.g., `describe`)
- Unique method detection: methods present on exactly 1 exchange (true uniqueness)
- Rare method detection: methods on fewer than 5 exchanges (superset of unique)
- Method count distribution: min/max/median/mean/p25/p75 of per-exchange method counts
- Cross-type analysis: identifies shared, REST-only, and WS-only method names
- Added `.dialyzer_ignore.exs` for known MapSet opaque type warnings (elixir-lang/elixir#9078)
- Key finding: very few methods are shared between REST and WS — CCXT maintains clean separation between `fetch*`/`parse*` (REST) and `watch*`/`handle*` (WS) patterns
- Integration tests verify per-exchange method coverage: each reference exchange's methods are checked against the family analysis output, not just global assertions

### Tasks 4a + 4b: REST & WS Method Inventory
- `CcxtExtract.Methods` — single module with `extract(:rest)` and `extract(:ws)` entry points, parses TS source via OXC
- `mix ccxt_extract.methods` — CLI task with `--type rest|ws` flag (defaults to both)
- Per-method metadata: name, async status, parameter names with TS type annotations, return type, statement count
- Parameter extraction handles five AST node shapes: `Identifier`, `AssignmentPattern` (defaults), `RestElement` (variadic), `ObjectPattern` (destructured), and unknown types
- Type annotation extraction handles `TSTypeReference`, `TSArrayType`, `TSUnionType`, and all TS keyword types (`string`, `number`, `void`, etc.)
- Output: `priv/discoveries/methods_rest.json` (110 exchanges, 5,508 methods) and `priv/discoveries/methods_ws.json` (79 exchanges, 2,434 methods)
- Key design: one module serves both REST and WS — only the glob directory differs, all parsing logic is shared

### Task 3b: Key Frequency Analysis
- `CcxtExtract.DescribeKeyAnalysis` — reads describe_keys.json and produces frequency analysis with tier classification
- `mix ccxt_extract.describe_key_analysis` — CLI task that runs analysis and writes `priv/discoveries/describe_key_analysis.json`
- Five frequency tiers: universal (100%), common (>90%), frequent (>50%), uncommon (≥5 exchanges, ≤50%), rare (<5 exchanges)
- Type consistency tracking: per-key breakdown of how many exchanges use each JS type (detects mixed types like `markets` being "object" on most but "undefined" on some)
- Max nesting depth per key via QuickBEAM — walks describe() value trees recursively across all exchanges, reports the deepest nesting seen
- Pure analysis functions (`analyze/1`, `build_key_stats/3`, `classify_tier/2`) fully testable with mock data, separate from QuickBEAM extraction
- Key decision: nesting depth extracted via separate QuickBEAM pass rather than enhancing describe_keys.json — keeps Task 3a output stable while adding depth data

### Task 3a: Extract describe() Top-Level Keys
- `CcxtExtract.DescribeKeys` — extracts all top-level keys and JS value types from every non-alias exchange's `describe()` via QuickBEAM
- `mix ccxt_extract.describe_keys` — CLI task that runs extraction and writes `priv/discoveries/describe_keys.json`
- Type detection uses JS `typeof` + `Array.isArray` + null check for accurate type strings: "string", "number", "boolean", "object", "array", "null", "function", "undefined"
- Aliases are skipped (they share describe() with their parent)
- Output includes `all_keys` summary — sorted list of every unique key seen across all exchanges
- Integration tests verify: reference exchange presence, universal keys (id/name/has/urls/api), type consistency, alias exclusion, data-driven `for`+`unquote` pattern

### Task 20: Expand Integration Tests to Reference Exchanges
- Data-driven tests using compile-time `for` + `unquote` — module attributes define exchange sets, `for` loops generate individual named tests
- **exchanges_integration_test:** All 13 reference exchanges exist and are not aliases, known aliases (huobi, gateio) correctly marked, variants (binanceus, binancecoinm, kucoinfutures) are not aliases
- **classes_integration_test:** REST class structure with method count thresholds per exchange, WS alias resolution (`fooRest -> rest:foo`) for all 13 references, variant/alias inheritance chains (binanceus→binance, huobi→htx, etc.), WS counterpart coverage
- **summary_integration_test:** Variant families (binance, kucoin), alias families (htx, gate), standalone families (bybit, deribit, coinbaseexchange, kraken, bitmex), DEX families (hyperliquid, aster, lighter), non-orphan alias verification
- Key design: reference coverage is data-driven via module attributes and compile-time test generation; family-specific expectations still live alongside the relevant test file

### Task 2c: Exchange Summary Stats
- `CcxtExtract.Summary` — reads exchanges.json + class_hierarchy.json, computes aggregate stats and family groupings
- `mix ccxt_extract.summary` — CLI task with console table output showing top families
- Family grouping algorithm: inverts inheritance tree, walks each REST class to root ancestor, classifies members as variants (own class) or aliases (alias=true in CCXT)
- Orphan alias detection: aliases with no class entry are collected separately; aliases with class entries are attached to their parent family
- Key decision: orphan aliases stored as top-level field rather than guessed into families — preserves data integrity over completeness

### Task 2b: OXC Class Hierarchy
- `CcxtExtract.Classes` — parses all CCXT TypeScript files with OXC, extracts class name, superclass, and method list per exchange
- `mix ccxt_extract.classes` — CLI task that runs extraction and writes `priv/discoveries/class_hierarchy.json`
- Inheritance tree built from `extends` relationships with Exchange as root parent
- WS counterpart detection — identifies exchanges with both REST and WS implementations
- Per-method metadata: name, async status, parameter count, statement count
- Handles edge cases: anonymous classes (fallback to filename), missing superclass, non-class exports

### Task 2b fix: Resolve WS import aliases, deduplicate tree, add error reporting
- **Import alias resolution:** WS classes import REST parents with aliases (`import binanceRest from '../binance.js'`). The extractor now resolves these aliases by parsing `ImportDeclaration` AST nodes, mapping alias names to their canonical class name and source type (`../` = REST, `./` = WS)
- **New fields:** `node_key` (unique `"type:id"` identity), `extends_raw` (literal AST value), `extends_resolved` (canonical parent name), `parent_key` (resolved parent node identity). Dropped ambiguous `extends` field
- **Tree deduplication:** `build_tree/1` now groups by `parent_key` with `node_key` as children — no more duplicate entries from REST/WS classes sharing the same `class_name`
- **Error reporting:** `extract/0` returns `{:ok, classes, stats}` with explicit `:skipped` and `:errors` lists. Parse failures logged via `Logger.warning/1` instead of silently dropped
- **Tighter integration tests:** Percentage-based assertions (zero parse errors, 100% file accounting), alias resolution checks (WS binance → `parent_key: "rest:binance"`), tree uniqueness validation

### Task 2a: QuickBEAM Exchange List
- `CcxtExtract.QuickbeamRuntime` — shared bootstrap module for all future QuickBEAM extraction tasks (start/stop with browser globals + CCXT bundle)
- `CcxtExtract.Exchanges` — extracts per-exchange metadata from CCXT runtime: id, name, certified, pro, version, country, alias, referral URL
- `mix ccxt_extract.exchanges` — CLI task that runs extraction and writes `priv/discoveries/exchanges.json`
- Referral URL normalization handles four CCXT variants: nil, plain string, object with discount, object without discount (e.g. hibachi)
- Discovery: CCXT has a fourth referral format — `%{"url" => "..."}` without a `"discount"` key — that wasn't documented in the task spec

### Path Resolution & Release Compatibility
- `CcxtExtract.Paths` — shared path resolution via `:code.priv_dir(:ccxt_extract)`, works in both Mix dev and compiled releases
- Setup task now copies CCXT browser bundle from `node_modules/` to `priv/ccxt_bundle.js` — extraction no longer depends on `node_modules/` at runtime
- All file paths across quickbeam_runtime, exchanges, and setup task now resolve through `CcxtExtract.Paths`

### Task 19: Fix Sparse Checkout Package.json
- `record_versions/0` now handles missing `priv/ccxt/package.json` gracefully with a warning instead of crashing
- Users following the sparse checkout instructions (`git sparse-checkout set ts/src`) no longer hit a setup crash

### Task 1: CCXT Source Setup
- `mix ccxt_extract.setup` mix task — installs npm bundle, checks TS source, verifies QuickBEAM and OXC
- Version tracking via `priv/ccxt_version.json` — records npm version, TS source version, git SHA, timestamp
- Warns on version mismatch between npm bundle and TS source
- Supports symlinked CCXT source (e.g., `ln -s ../ccxt priv/ccxt`)
- Discovery: `set_global(rt, "self", :global_this)` doesn't create `self === globalThis` — must use `QuickBEAM.eval` to set browser globals instead
- Added `:mix` to dialyzer PLT apps

### Task 18: Fix QuickBEAM Browser Global Pattern
- Examples 3 and 4 updated: replaced `set_global(rt, "self", :global_this)` with the JS assignment pattern for setting browser globals
- `set_global` with atoms converts to strings, not globalThis identity — discovered during Task 1

### Project Setup
- Initial project creation with OXC, QuickBEAM, and npm_ex dependencies
- 5 example scripts demonstrating both extraction tools
- CLAUDE.md with mission, tools, and anti-bias rules
- ROADMAP.md with 4-phase discovery-first approach
