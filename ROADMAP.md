# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON data, consumable by any programming language.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

---

## 🎯 Current Focus

**Phase 3: Structural Extraction** — Next up. Five independent `[P]` tasks extracting method ASTs.

### ✅ Recently Completed
| Task | Description | Notes |
|------|-------------|-------|
| Task 7 | Exchange family analysis | Multi-member and standalone families identified; describe() universally overridden; variants mostly differ in config, not implementation |
| Task 8c | Market data validation | Two-layer validation: structural (offline) + spot-check (live API) |
| Task 22 | Split integration tests into cached/extraction tiers | Cached tests read tracked fixtures; write!/1 serializer tests in fast tier |

### 📋 Current Tasks
| Task | Status | Notes |
|------|--------|-------|
| Task 9 `[P]` | ⬜ | sign() extraction [D:4/B:9/U:9 → Eff:2.25] |
| Task 10 `[P]` | ⬜ | handleErrors() extraction [D:4/B:8/U:8 → Eff:2.00] |
| Task 11 `[P]` | ⬜ | parse*() extraction [D:5/B:9/U:8 → Eff:1.70] |
| Task 12 `[P]` | ⬜ | WS method extraction [D:5/B:8/U:7 → Eff:1.50] |
| Task 13 | ⬜ | Class hierarchy and overrides [D:6/B:8/U:8 → Eff:1.33] |

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

## Phase 3: Structural Extraction — OXC AST [D:7/B:9/U:8 → Eff:1.21]

> OXC parses TypeScript source into AST. Use it for structural data that QuickBEAM can't provide: method bodies, signing logic, error handling patterns, field mappings. **Output raw ESTree AST as JSON** — don't pre-classify or reduce to patterns. Consumers decide whether to pattern-match the AST (parameterized patterns) or transpile it (code generation). The AST is the data.

### Tasks

- [ ] **Task 9: sign() method extraction** [D:4/B:9/U:9 → Eff:2.25] `[P]` — Extract the `sign()` method body as raw ESTree AST (JSON) for every exchange. This is how each exchange authenticates API requests. Output the full AST — don't classify into patterns, don't pre-categorize. The raw AST is the data.

- [ ] **Task 10: handleErrors() extraction** [D:4/B:8/U:8 → Eff:2.00] `[P]` — Extract `handleErrors()` body as raw ESTree AST for every exchange. How does each exchange map HTTP responses to error types? Output the full method AST alongside the exceptions from describe(). Don't reduce to a lookup table — the AST captures conditional logic, fallthrough, and edge cases that a table would lose.

- [ ] **Task 11: parse*() method extraction** [D:5/B:9/U:8 → Eff:1.70] `[P]` — Extract all `parse*` method bodies as raw ESTree AST (parseTicker, parseOrder, parseTrade, parseBalance, etc.). These contain field-by-field mappings from exchange-specific format to CCXT's unified format. Output the full AST per method.

- [ ] **Task 12: WS method extraction** [D:5/B:8/U:7 → Eff:1.50] `[P]` — Extract all `watch*` and `handle*` methods from `pro/*.ts` as raw ESTree AST. These define WebSocket subscription and message handling. Output full method ASTs — channel names, message formats, and subscription logic are all embedded in the code and should be preserved structurally.

- [ ] **Task 13: Class hierarchy and overrides** [D:6/B:8/U:8 → Eff:1.33] — Build the complete class hierarchy tree. For each exchange that extends another, identify exactly which methods are overridden and include the override's AST. This tells consumers both what's unique about each exchange AND gives them the code to work with.

---

## Phase 4: Output Format & Validation [D:5/B:8/U:9 → Eff:1.70]

> Design the output format AFTER you know what data exists. Not before.

### Tasks

- [ ] **Task 14: Design output schema** [D:5/B:9/U:9 → Eff:1.80] — Based on everything discovered in Phases 1-3, design a JSON schema for the per-exchange output. The schema should reflect CCXT's actual structure, not any consumer's needs. Use JSON-native types only (strings, numbers, booleans, arrays, objects, null). Include a formal JSON Schema spec so any language can validate. The output has two layers: (1) resolved runtime data from QuickBEAM (describe, markets — values), and (2) raw ESTree AST from OXC (method bodies — code as data). Both are JSON. Consumers choose per-method whether to interpret the AST as patterns or transpile it.

- [ ] **Task 15: Full extraction pipeline** [D:5/B:9/U:9 → Eff:1.80] — Build the pipeline that runs QuickBEAM + OXC extraction for all exchanges and writes per-exchange JSON files. Should be runnable via a single mix task. Deterministic: same input = same output.

- [ ] **Task 16: Validation** [D:4/B:8/U:8 → Eff:2.00] — Round-trip validate: load each JSON file, compare key sections against QuickBEAM runtime output. Ensure nothing was lost or transformed incorrectly. Report any discrepancies.

- [ ] **Task 17: Coverage report** [D:3/B:7/U:8 → Eff:2.50] — For each exchange, report what was extracted and what wasn't. Are there describe() keys we missed? Methods we didn't catalog? Any exchange that failed extraction? The goal is 100% coverage of what CCXT knows.

---

## Notes

- Tasks are written as prompts for Claude to implement — explore the codebase and discover the right approach
- Phase order matters: Discovery first, then runtime extraction, then structural, then output format
- The output format in Phase 4 is designed AFTER Phases 1-3 reveal what data actually exists
- See `examples/` for working OXC and QuickBEAM scripts to understand the tools
- **AST as data, not as code**: CCXT's own transpiler (ast-transpiler + regex post-processing) converts TS AST → target language code. We take a different approach: extract the AST as JSON data. This gives consumers maximum flexibility — they can pattern-match it (parameterized patterns like "9 signing types"), transpile it (AST → Elixir/Rust code), or analyze it (dashboards, capability discovery). The extraction layer doesn't decide which strategy is right.
- **Two-layer output**: QuickBEAM gives resolved values (what an exchange IS — config, capabilities, markets). OXC gives structural AST (what an exchange DOES — signing logic, parsing logic, error handling). Both are JSON. Both are complete. Together they capture everything CCXT knows.
