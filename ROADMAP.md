# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON data. The single source of truth for any CCXT consumer library — Elixir, Rust, Go, Python.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

---

## 🎯 Current Focus

**Phase 5: Distribution** — Make extracted data consumable by any language (Elixir, Rust, Go, Python).

> **Architecture decision**: ccxt_extract replaces ccxt_ex's extraction pipeline. ccxt_ex retires. Consumer libraries (ccxt_client for Elixir, future Rust/Go/Python libs) consume ccxt_extract's JSON output directly. The JSON is the contract — no Hex package needed, just `mix ccxt_extract.pipeline --output <path>`.

### ✅ Recently Completed
| Task | Description | Notes |
|------|-------------|-------|
| Task 23 | Resolve `__function:` sentinels | Error class names now resolved via instance name map |
| Task 16 | Full validation | JSV schema + round-trip comparison; 110 exchanges, 0 errors |
| Task 15 | Full extraction pipeline | `mix ccxt_extract.pipeline` assembles per-exchange validated JSON |
| Task 14 | Output schema design | JSON Schema (exchange_v1.json); two-layer model (runtime + structure) |
| Task 17 | Coverage report | 86.7% avg coverage; all 10 layers tracked per exchange |

### 📋 Current Tasks
| Task | Status | Notes |
|------|--------|-------|
| Task 25 | ⬜ | Configurable output directory (`--output`) |
| Task 26 | ⬜ | CCXT version pinning and reproducibility |
| Task 27 | ⬜ | Schema versioning contract |
| Task 28 | ⬜ | Update workflow (re-extract on CCXT bump) |

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
mix ccxt_extract.coverage                      # Generate extraction coverage report
mix ccxt_extract.pipeline                      # Assemble per-exchange JSON output
mix ccxt_extract.validate                      # Full JSON Schema + round-trip validation
mix ccxt_extract.validate --strict             # Fail on errors (CI mode)
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

## Phase 5: Distribution ⬜

> Make ccxt_extract's output consumable by any language. The JSON files are the product — delivery is `mix ccxt_extract.pipeline --output <target_dir>`. Consumer libraries (Elixir, Rust, Go) check the JSON into their own repos and build from it.

- [ ] **Task 25: Configurable output directory** [D:2/B:9/U:9 → Eff:4.50] 🎯 — Add `--output <path>` flag to `mix ccxt_extract.pipeline`. Defaults to `priv/output/` (current behavior). When specified, writes all per-exchange JSON + manifest + schema to the target directory. Include `--clean` flag to remove stale exchange files in target that no longer exist in extraction. Pattern: `mix ccxt_extract.pipeline --output ../ccxt_client/priv/specs`.

- [ ] **Task 26: CCXT version pinning and reproducibility** [D:3/B:8/U:8 → Eff:2.67] 🎯 — Record the exact CCXT version (git tag or commit SHA) in the manifest and each per-exchange JSON. Add `--ccxt-version` flag to `mix ccxt_extract.setup` to pin a specific CCXT release tag. Ensure same CCXT version + same extraction code = identical output (deterministic). Document the version in `_manifest.json` so consumers know what they're building from.

- [ ] **Task 27: Schema versioning contract** [D:2/B:7/U:8 → Eff:3.75] 🎯 — Document the schema stability promise: `schema_version` in output JSON is the consumer contract. Patch version (1.0.x) = additive fields only. Minor version (1.x.0) = structural changes that don't break existing field access. Major version (x.0.0) = breaking changes. Add a `SCHEMA.md` documenting the contract and what each version guarantees. Consumers can check `schema_version` and fail fast on incompatible data.

- [ ] **Task 28: Update workflow** [D:3/B:7/U:7 → Eff:2.33] 🎯 — Document and automate the re-extraction workflow when CCXT releases a new version. Steps: update CCXT source (`mix ccxt_extract.setup --latest`), re-run pipeline (`mix ccxt_extract.pipeline --output <target>`), validate (`mix ccxt_extract.validate --strict`). Could be a single `mix ccxt_extract.update --output <target>` that chains all three. Include diff summary: how many exchanges changed, what fields changed.

---

## Data Quality

- [x] ~~**Task 23: Resolve __function: sentinels in describe data**~~ [D:5/B:7/U:7 → Eff:1.40] — See [CHANGELOG.md](CHANGELOG.md#unreleased)

- [ ] **Task 24: Use Parity.Compare for richer round-trip diff output** [D:3/B:5/U:4 → Eff:1.50] 📋 — Replace `==` equality checks in `Validation.check_data_equality/5` with `Parity.Compare.compare/3` from `../ccxt_parity`. Currently round-trip findings say "data mismatch" — with Parity.Compare they'd show the exact path and expected vs actual values. Either add as path dep or extract to hex first.

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

- Tasks are written as prompts for Claude to implement — explore the codebase and discover the right approach
- Phase order matters: Discovery first, then runtime extraction, then structural, then output format
- The output format in Phase 4 is designed AFTER Phases 1-3 reveal what data actually exists
- See `examples/` for working OXC and QuickBEAM scripts to understand the tools
- **AST as data, not as code**: CCXT's own transpiler (ast-transpiler + regex post-processing) converts TS AST → target language code. We take a different approach: extract the AST as JSON data. This gives consumers maximum flexibility — they can pattern-match it (parameterized patterns like "9 signing types"), transpile it (AST → Elixir/Rust code), or analyze it (dashboards, capability discovery). The extraction layer doesn't decide which strategy is right.
- **Two-layer output**: QuickBEAM gives resolved values (what an exchange IS — config, capabilities, markets). OXC gives structural AST (what an exchange DOES — signing logic, parsing logic, error handling). Both are JSON. Both are complete. Together they capture everything CCXT knows.
