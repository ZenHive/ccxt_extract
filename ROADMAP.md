# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON data. The single source of truth for any CCXT consumer library — Elixir, Rust, Go, Python.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

---

## 🎯 Current Focus

**Phase 7: Data Quality & Maintenance** — Technical debt and code quality improvements.

> **Architecture decision**: ccxt_extract replaces ccxt_ex's extraction pipeline. ccxt_ex retires. Consumer libraries (ccxt_client for Elixir, future Rust/Go/Python libs) consume ccxt_extract's JSON output directly. The JSON is the contract — no Hex package needed, just `mix ccxt_extract.pipeline --output <path>`.

### ✅ Recently Completed
| Task | Description | Notes |
|------|-------------|-------|
| Task 45 | Include derived analytics in update | `mix ccxt_extract.update` now runs Stage 6: coverage, summary, family analysis, method analysis, public exchanges, market validation. QuickBEAM-dependent analytics (describe keys, describe key analysis) skipped with `--skip-setup`. |
| Task 44 | Resolve alias exchange data from parent | Alias exchanges (coinbaseadvanced, gateio, huobi) now inherit parent runtime data (describe, markets, symbol_patterns) via class hierarchy fallback. Validation alias-aware. |
| Task 42 | Follow super.*() delegation in unified endpoints | Resolves super.method() calls through base Exchange class. Fixes coincatch and kucoin missing transport mappings. |
| Task 41 | Unified endpoint mappings | Maps unified methods to interface methods via AST walking. Derived exchanges inherit parent mappings. Schema 1.1.0. Fixed: dispatch helper exclusion, mixed direct+delegate merging, multi-hop delegation (depth 3 with cycle protection). |
| Task 40 | Symbol pattern derivation | Pure derivation from `runtime.markets` — separator, case, structure, suffix, anomalies per market type. Schema 1.0.1. Fixed: case anomaly detection, dominant_value nil inflation, suffix anomaly undercounting. Added round-trip validation. |
| Task 35 | Extract shared modules | `CcxtExtract.OXCExtractor` behaviour (6 modules) + `CcxtExtract.MethodAST` (5 modules). 35c deferred. |
| Task 28 | Update workflow | `mix ccxt_extract.update` chains setup → pipeline → validate with diff summary. Validation reads emitted JSON from disk (not in-memory). |
| Task 39 | Pagination round-trip validation | Pagination now compared between discovery and pipeline output; presence + data equality checks with `_unresolved` support |
| Task 26 | CCXT version pinning and reproducibility | `--ccxt-version` and `--latest` flags update both npm bundle and TS source atomically; `source_git_sha` in manifest; manifest version from exchange data |
| Task 38 | Pagination data quality fixes | Branch-dependent variants preserved (always arrays), unresolved variable method names captured, provenance tracking via containing_method |
| Task 32 | Pagination strategy extraction | 4 strategies (dynamic/deterministic/cursor/incremental), 43 exchanges; recursive AST walker for nested calls |
| Task 27 | Schema versioning contract | `SCHEMA.md` documents semver contract for `schema_version` field; consumer guidance for Elixir/Rust/Python |
| Task 31 | Base normalizer methods from `Exchange.ts` | Global artifact `_base_methods.json`: MethodDefinition signatures + PropertyDefinition field aliases, with `source` field |
| Task 30 | Interface signatures from `abstract/*.ts` | Fixed: now extracts all 110 exchanges (was 99 — alias exchanges skipped); round-trip validation wired up |
| Task 25 | Configurable output directory | `--output` now emits per-exchange JSON, `_manifest.json`, and `exchange_v1.json`; stale exchange files are cleaned automatically |
| Task 29 | Comparison script vs old ccxt_client specs | 100% coverage; all old keys classified as covered/richer/consumer-specific |
| Task 23 | Resolve `__function:` sentinels | Error class names now resolved via instance name map |
| Task 16 | Full validation | JSV schema + round-trip comparison; 110 exchanges, 0 errors |
| Task 15 | Full extraction pipeline | `mix ccxt_extract.pipeline` assembles per-exchange validated JSON |
| Task 14 | Output schema design | JSON Schema (exchange_v1.json); two-layer model (runtime + structure) |
| Task 17 | Coverage report | 86.7% avg coverage; all 10 layers tracked per exchange |

### 📋 Current Tasks
| Task | Status | Notes |
|------|--------|-------|
| Task 35 | ✅ | Extract shared modules — OXCExtractor + MethodAST |
| Task 26 | ✅ | CCXT version pinning and reproducibility |
| Task 27 | ✅ | Schema versioning contract — `SCHEMA.md` |
| Task 28 | ✅ | Update workflow — `mix ccxt_extract.update` |

### 📋 Go Extractor Parity (Phase 6)
| Task | Status | Notes |
|------|--------|-------|
| Task 30 | ✅ | Interface signatures from `abstract/*.ts` |
| Task 31 `[P]` | ✅ | Base normalizer methods from `Exchange.ts` (MethodDefinitions + PropertyDefinitions) |
| Task 32 `[P]` | ✅ | Pagination strategy per method per exchange |
| Task 33 | 🔶 Deferred | Auth assembly decomposition — deferred: this is interpretation, not extraction. The raw sign() AST is already extracted. Consumers should classify signing patterns from AST, not consume pre-digested "recipes" that bake in one model. Revisit only if multiple consumers independently request it. |
| Task 34 | 🔶 Deferred | Handler routing tables — deferred: derivable from existing AST bodies. Adding pre-computed routing tables is analysis, not extraction, and couples the extractor to a specific consumer's view of method dependencies. |

### 📋 Data Quality & Maintenance
| Task | Status | Notes |
|------|--------|-------|
| Task 35 | ✅ | Extract shared modules — OXCExtractor + MethodAST (35c deferred) |
| Task 36 | 🔶 Deferred | Schema migration framework — deferred: premature. Zero consumers using v1.0 yet. Build migration tooling when a real v2.0 need emerges with concrete requirements, not speculatively. |
| Task 37 | ⬜ | Fix Credo compatibility on Elixir 1.18+ |
| Task 38 | ✅ | Pagination data quality: branch-dependent duplicates + variable method names |
| Task 39 | ✅ | Pagination round-trip validation — presence + data equality checks with `_unresolved` support |
| Task 44 | ✅ | Resolve alias exchange data from parent (coinbaseadvanced, gateio, huobi) |
| Task 45 | ✅ | Include derived analytics in `mix ccxt_extract.update` |

### Quick Commands
```bash
mix ccxt_extract.exchanges                 # Extract exchange metadata
mix ccxt_extract.classes                   # Extract class hierarchy
mix ccxt_extract.summary                   # Combine into summary stats
mix ccxt_extract.describe                  # Extract full describe() per exchange
mix ccxt_extract.describe_keys             # Extract describe() keys per exchange
mix ccxt_extract.describe_key_analysis     # Analyze key frequency and nesting depth
mix ccxt_extract.methods                   # Extract REST + WS method inventory
mix ccxt_extract.methods --type rest       # REST only
mix ccxt_extract.methods --type ws         # WS only
mix ccxt_extract.method_analysis           # Analyze method families and distribution
mix ccxt_extract.public_exchanges          # Identify public exchanges for loadMarkets()
mix ccxt_extract.load_markets              # Extract loadMarkets() data (live API calls)
mix ccxt_extract.load_markets --concurrency 10  # Faster with more parallel workers
mix ccxt_extract.validate_markets              # Validate cached market data (structural)
mix ccxt_extract.validate_markets --spot-check # + live spot-check against exchange APIs
mix ccxt_extract.family_analysis               # Analyze exchange families
mix ccxt_extract.sign_methods                  # Extract sign() method AST
mix ccxt_extract.handle_errors                 # Extract handleErrors() method AST
mix ccxt_extract.parse_methods                 # Extract parse*() method ASTs
mix ccxt_extract.ws_methods                    # Extract watch*/handle* WS method ASTs
mix ccxt_extract.overrides                     # Extract method overrides for derived exchanges
mix ccxt_extract.interface_signatures          # Extract interface signatures from abstract/*.ts
mix ccxt_extract.base_methods                  # Extract base class methods from Exchange.ts
mix ccxt_extract.pagination                    # Extract pagination strategies per exchange
mix ccxt_extract.unified_endpoints             # Extract unified method → interface method mappings
mix ccxt_extract.coverage                      # Generate extraction coverage report
mix ccxt_extract.pipeline                      # Assemble per-exchange JSON output
mix ccxt_extract.validate                      # Full JSON Schema + round-trip validation
mix ccxt_extract.validate --strict             # Fail on errors (CI mode)
mix ccxt_extract.update                        # Full re-extract: setup → extractors → pipeline → validate → analytics
mix ccxt_extract.update --latest --output /tmp # Update to latest CCXT, custom output
mix ccxt_extract.update --skip-setup           # Re-run pipeline + validate + analytics (skips QuickBEAM analytics)
mix ccxt_extract.setup                     # Setup CCXT sources
mix run examples/3_quickbeam_describe.exs  # Test QuickBEAM
mix run examples/1_parse_exchange.exs binance  # Test OXC
mix test.json --quiet                      # Fast tests (~0.4s, cached only)
mix test.json --quiet --include extraction # Full tests (includes QuickBEAM/OXC)
mix test.json --quiet --only extraction    # Only extraction tests
```

---

## Phase 1: Setup & Discovery ✅

> All discovery tasks complete. See [DISCOVERIES.md](DISCOVERIES.md) for synthesized findings.

### Tasks

- [x] ~~Task 1: CCXT source setup~~ — See [CHANGELOG.md](CHANGELOG.md#unreleased)
- [x] ~~Task 18: Fix QuickBEAM browser globals~~ — See [CHANGELOG.md](CHANGELOG.md#unreleased)
- [x] ~~**Task 19: Fix sparse checkout to include package.json**~~ — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 2: Exchange inventory**~~ — Catalog every exchange with metadata and hierarchy.
  - [x] ~~**2a: QuickBEAM exchange list**~~ [D:3/B:8/U:9 → Eff:2.83] `[P]` — Load CCXT via QuickBEAM, extract per-exchange: `id`, `name`, `certified`, `pro`, `version`, `country`, `alias`. Mark aliases explicitly (`alias: true` in describe() = pure re-brands like `huobi`→`htx`). Extract referral URLs from `describe().urls.referral` (two formats: plain string URL, or `{url, discount}` object) — normalize to `{url, discount}` format. Write `priv/discoveries/exchanges.json`. Reuse pattern from `examples/3_quickbeam_describe.exs`.
  - [x] ~~**2b: OXC class hierarchy**~~ [D:3/B:8/U:9 → Eff:2.83] — See [CHANGELOG.md](CHANGELOG.md#unreleased)
  - [x] ~~**2c: Exchange summary stats**~~ [D:2/B:6/U:7 → Eff:3.25] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 3: describe() key inventory**~~ — Catalog every key in every exchange's describe().
  - [x] ~~**3a: Extract all describe() top-level keys**~~ [D:3/B:8/U:8 → Eff:2.67] — See [CHANGELOG.md](CHANGELOG.md#unreleased)
  - [x] ~~**3b: Key frequency analysis**~~ [D:2/B:7/U:7 → Eff:3.50] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 4: Method inventory**~~ — Catalog every method on every exchange with signatures.
  - [x] ~~**4a: REST exchange methods**~~ [D:3/B:8/U:8 → Eff:2.67] `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)
  - [x] ~~**4b: WS exchange methods**~~ [D:2/B:7/U:7 → Eff:3.50] `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)
  - [x] ~~**4c: Method family analysis**~~ [D:2/B:7/U:8 → Eff:3.75] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 20: Expand integration tests to reference exchanges**~~ [D:3/B:7/U:8 → Eff:2.50] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 21: Extract shared test helpers**~~ [D:1/B:4/U:5 → Eff:4.50] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 22: Split integration tests into cached/extraction tiers**~~ [D:3/B:8/U:9 → Eff:2.83] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 5: Document discoveries**~~ [D:2/B:7/U:9 → Eff:4.00] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

---

## Phase 2: Runtime Extraction — QuickBEAM ✅

> All runtime extraction tasks complete. See [CHANGELOG.md](CHANGELOG.md#unreleased) for details.
> Built: Full describe() extraction, exchange family analysis, loadMarkets() with validation, credential classification.

### Tasks

- [x] ~~**Task 6: Full describe() extraction**~~ [D:4/B:9/U:9 → Eff:2.25] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 7: Exchange family analysis**~~ [D:5/B:7/U:7 → Eff:1.40] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 8: loadMarkets() extraction**~~ — For exchanges with public API access (no auth needed), run `loadMarkets()` via QuickBEAM. Extract market listings: symbol formats, precision, limits, market types (spot, swap, future, option), fee structures. This is live API data.
  - [x] ~~**8a: Identify public exchanges**~~ [D:2/B:6/U:8 → Eff:3.50] — See [CHANGELOG.md](CHANGELOG.md#unreleased)
  - [x] ~~**8b: Rate-limited extraction**~~ [D:5/B:8/U:8 → Eff:1.60] — See [CHANGELOG.md](CHANGELOG.md#unreleased)
  - [x] ~~**8c: Market data validation**~~ [D:3/B:7/U:7 → Eff:2.33] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

---

## Phase 3: Structural Extraction — OXC AST ✅

> 5 tasks complete. See [CHANGELOG.md](CHANGELOG.md#unreleased) for details.
> Built: sign(), handleErrors(), parse*(), WS methods (watch*/handle*), class hierarchy overrides — all as raw ESTree AST JSON.

### Tasks

- [x] ~~**Task 9: sign() method extraction**~~ [D:4/B:9/U:9 → Eff:2.25] `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 10: handleErrors() extraction**~~ [D:4/B:8/U:8 → Eff:2.00] `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 11: parse*() method extraction**~~ [D:5/B:9/U:8 → Eff:1.70] `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 12: WS method extraction**~~ [D:5/B:8/U:7 → Eff:1.50] `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 13: Class hierarchy and overrides**~~ [D:6/B:8/U:8 → Eff:1.33] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

---

## Phase 4: Output Format & Validation ✅

> 4 tasks complete. See [CHANGELOG.md](CHANGELOG.md#unreleased) for details.
> Built: JSON Schema (exchange_v1.json), extraction pipeline, coverage report, full validation (JSV + round-trip).

### Tasks

- [x] ~~**Task 14: Design output schema**~~ [D:5/B:9/U:9 → Eff:1.80] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 15: Full extraction pipeline**~~ [D:5/B:9/U:9 → Eff:1.80] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 16: Validation**~~ [D:4/B:8/U:8 → Eff:2.00] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 17: Coverage report**~~ [D:3/B:7/U:8 → Eff:2.50] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

---

## Phase 5: Distribution ✅

> All distribution tasks complete. See [CHANGELOG.md](CHANGELOG.md#unreleased) for details.
> Built: Configurable output (`--output`), CCXT version pinning (`--ccxt-version`/`--latest`), schema versioning contract (SCHEMA.md), update orchestration (`mix ccxt_extract.update`).

- [x] ~~**Task 25: Configurable output directory**~~ [D:2/B:9/U:9 → Eff:4.50] 🎯 — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 26: CCXT version pinning and reproducibility**~~ [D:3/B:8/U:8 → Eff:2.67] 🎯 — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 27: Schema versioning contract**~~ [D:2/B:7/U:8 → Eff:3.75] 🎯 — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 28: Update workflow**~~ [D:3/B:7/U:7 → Eff:2.33] 🎯 — See [CHANGELOG.md](CHANGELOG.md#unreleased)

---

## Phase 6: Go Extractor Parity ⬜

> The Go extractor (ccxt_go_extractor) extracts 5 categories we don't yet cover. All are extractable from TS source via OXC. Achieving parity means ccxt_extract fully supersedes both the old Elixir specs AND the Go extractor.

- [x] ~~**Task 30: Interface signatures from abstract/*.ts**~~ [D:3/B:8/U:9 → Eff:2.83] 🎯 `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 31: Base normalizer methods from Exchange.ts**~~ [D:3/B:7/U:8 → Eff:2.50] 🎯 `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 32: Pagination strategy extraction**~~ [D:4/B:7/U:7 → Eff:1.75] 🚀 `[P]` — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [ ] **Task 33: Auth assembly decomposition** [D:6/B:8/U:8 → Eff:1.33] 📋 🔶 **Deferred** — Decompose the existing `sign_method` AST into structured auth assembly steps. **Deferred reason:** This crosses from extraction into interpretation. The raw sign() AST is already extracted and complete. Classifying signing patterns (which crypto ops, what gets signed) is consumer-domain work — ccxt_client's 9 signing patterns are *its* abstraction, not a universal truth. Baking one interpretation into the extractor couples it to one consumer's model. Revisit only if multiple consumers independently request structured signing recipes.

- [ ] **Task 34: Handler routing extraction** [D:5/B:7/U:7 → Eff:1.40] 📋 🔶 **Deferred** — Extract method → handler dependency routing tables. **Deferred reason:** This is analysis derivable from existing AST data. Every method body is already extracted — consumers can walk `this.handleErrors()`, `this.sign()` calls themselves. Pre-computing one routing view in the extractor removes consumer flexibility. Revisit only if AST walking proves impractical for multiple consumers.

---

## Phase 7: Data Quality & Maintenance ⬜

> Technical debt and code quality improvements identified during codebase review. These tasks improve maintainability and long-term sustainability.

- [x] ~~**Task 35: Extract shared modules to reduce duplication**~~ [D:4/B:7/U:8 → Eff:2.00] ✅ — See [CHANGELOG.md](CHANGELOG.md#unreleased). 35a (OXCExtractor) and 35b (MethodAST) complete. 35c (DiscoveryLoader) deferred — Pipeline loaders already well-factored.

- [ ] **Task 36: Schema migration framework** [D:2/B:5/U:6 → Eff:3.00] 📋 `[Codex]` 🔶 **Deferred** — Add `CcxtExtract.Schema.Migrator` module for future schema version upgrades. **Deferred reason:** Premature — v1.0.0 has zero consumers yet. Migration needs will be concrete when v2.0 actually arrives. Building a framework for hypothetical future migrations is speculative infrastructure that will likely not match real requirements.

- [x] ~~**Task 45: Include derived analytics in `mix ccxt_extract.update`**~~ [D:3/B:5/U:4 → Eff:1.50] ✅ — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [ ] **Task 37: Fix Credo compatibility on Elixir 1.18+** [D:2/B:4/U:3 → Eff:1.50] 🔧 `[Codex]` — Credo 1.7.x crashes on multi-line `~w` sigils and certain `~r` patterns due to tokenization bug in `Credo.Code.Token.position/1`. **Workaround applied:** switched to `github: "rrrene/credo", branch: "release/1.7"` git dep which includes the fix. Remaining: switch back to hex release (`~> 1.8`) when published. Low impact — `mix test` and `mix dialyzer` both pass, Credo is dev-only.

---

## Data Quality

- [x] ~~**Task 23: Resolve __function: sentinels in describe data**~~ [D:5/B:7/U:7 → Eff:1.40] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [ ] **Task 24: Use Parity.Compare for richer round-trip diff output** [D:3/B:5/U:4 → Eff:1.50] 📋 🔶 **Deferred** — Replace `==` equality checks in `Validation.check_data_equality/5` with `Parity.Compare.compare/3` from `../ccxt_parity`. **Deferred reason:** Adds path dependency on sibling project, coupling the extractor to ccxt_parity. The extractor should be self-contained. If richer diff output is needed, improve it inline rather than importing external deps.

- [x] ~~**Task 38: Pagination data quality — branch-dependent duplicates and variable method names**~~ [D:4/B:6/U:5 → Eff:1.38] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 39: Add pagination to round-trip validation**~~ [D:2/B:5/U:4 → Eff:2.25] ✅ — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 42: Follow `super.*()` delegation in unified endpoint extraction**~~ [D:5/B:5/U:4 → Eff:0.90] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [x] ~~**Task 43: Add test coverage for `super.*()` unified endpoint delegation**~~ [D:2/B:3/U:3 → Eff:1.50] — Included in Task 42 implementation (7 unit tests for super delegation).

- [x] ~~**Task 44: Resolve alias exchange data from parent**~~ [D:3/B:7/U:7 → Eff:2.33] ✅ — See [CHANGELOG.md](CHANGELOG.md#unreleased)

---

## Consumer Architecture

> This section documents how downstream projects consume ccxt_extract's output. Not tasks — reference for future instances.

**The pipeline:**
```
ccxt_extract                          Consumer projects
─────────────                         ─────────────────
mix ccxt_extract.pipeline \
  --output ../ccxt_client/priv/specs   →  Elixir: Generator macros read JSON at compile time
  --output ../ccxt_rust/data           →  Rust: build.rs / serde_json at compile time
  --output ../ccxt_python/data         →  Python: json.load at import time
```

**ccxt_ex retires.** Its extraction half is replaced by ccxt_extract. Its runtime half (signing patterns, HTTP client, WS, generator macros) moves to a new ccxt_client that reads ccxt_extract's JSON — not ccxt_ex's specs. The old ccxt_client's data model is NOT the template; only its Req and ZenWebsocket usage patterns are worth referencing.

**The JSON is the contract.** `exchange_v1.json` schema defines what consumers can rely on. Changes follow semver (see Task 27).

---

## Notes

- **`[Codex]` marker** — tasks suitable for Codex/OpenAI delegation: self-contained, well-specified, no OXC/QuickBEAM NIF deps, no cached fixture testing. Phase 6 (Go parity) tasks all require OXC AST work and pipeline integration — keep those in-house.
- Tasks are written as prompts for Claude to implement — explore the codebase and discover the right approach
- Phase order matters: Discovery first, then runtime extraction, then structural, then output format
- The output format in Phase 4 is designed AFTER Phases 1-3 reveal what data actually exists
- See `examples/` for working OXC and QuickBEAM scripts to understand the tools
- **AST as data, not as code**: CCXT's own transpiler (ast-transpiler + regex post-processing) converts TS AST → target language code. We take a different approach: extract the AST as JSON data. This gives consumers maximum flexibility — they can pattern-match it (parameterized patterns like "9 signing types"), transpile it (AST → Elixir/Rust code), or analyze it (dashboards, capability discovery). The extraction layer doesn't decide which strategy is right.
- **Two-layer output**: QuickBEAM gives resolved values (what an exchange IS — config, capabilities, markets). OXC gives structural AST (what an exchange DOES — signing logic, parsing logic, error handling). Both are JSON. Both are complete. Together they capture everything CCXT knows.
