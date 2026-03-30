# Changelog

Completed roadmap tasks. For upcoming work, see [ROADMAP.md](ROADMAP.md).

---

## [Unreleased]

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
