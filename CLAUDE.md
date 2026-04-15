# CLAUDE.md

@~/.claude/includes/across-instances.md
@~/.claude/includes/critical-rules.md
@~/.claude/includes/task-prioritization.md
@~/.claude/includes/task-writing.md
@~/.claude/includes/web-command.md
@~/.claude/includes/code-style.md
@~/.claude/includes/development-philosophy.md
@~/.claude/includes/documentation-guidelines.md
@~/.claude/includes/workflow-philosophy.md
@~/.claude/includes/skills-awareness.md
@~/.claude/includes/elixir-patterns.md
@~/.claude/includes/elixir-setup.md
@~/.claude/includes/development-commands.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/dialyzer-json.md
@~/.claude/includes/cli-aliases.md
@~/.claude/includes/elixir-volt.md
@~/.claude/includes/oxc.md
@~/.claude/includes/quickbeam.md
@~/.claude/includes/library-design.md

## Mission

Extract **everything** CCXT knows about 111+ cryptocurrency exchanges into language-agnostic JSON that any consumer in any language can drop in and use without walking AST.

Output: plain maps, JSON-serializable. No Elixir atoms, no structs, no language-specific types. The output must be consumable by any language — Elixir, Rust (`serde_json::from_str`), Python, Go — including consumers that generate code from the JSON (Elixir `use` macros, Rust proc-macros, Python codegen).

**Consumer contract:** A consumer should never need to parse, walk, or pattern-match ESTree AST to do its job. If they have to, we failed. Raw AST stays in the output for verification and novel needs, but every capability a consumer needs (signing, request building, response parsing, error handling, WS dispatch) must be expressible as declarative data.

## The One Rule

**Extract EVERYTHING. Never filter.**

"Never filter" applies **per-exchange, per-field** — every field, every method,
every AST node is extracted for every in-scope exchange. *Which* exchanges are
in scope is controlled by scope flags (`--tier1/--tier2/--tier3/--dex/--all/--exchange ID`,
see "Tier-Based Scoping" below); default is all 110.

CCXT has 7+ years of accumulated exchange knowledge. Every field exists for a reason. If CCXT's `describe()` returns 32 keys, extract 32 keys. If an exchange has 166 methods, catalog 166 methods. Storage is cheap; missing data is expensive.

"Everything" includes both **raw extraction** (AST, runtime values) and **derived data** (classifications, field maps, enum tables, recipes) — see "Raw vs Derived vs Override" below.

This rule is absolute for **raw** extraction — AST, resolved `describe()`, runtime probes — across all 110 exchanges. **Derived** recipes (signing assembly, fee schedules, error handlers) are scoped to priority tiers; non-priority exchanges receive `null + reason` per the Honesty Rule until a consumer surfaces a need. Overrides land on demand. See "Tier-Based Scoping" below.

## Raw vs Derived vs Override

The output has three provenance tiers, merged into one canonical JSON per exchange:

1. **Raw** — direct extraction from CCXT source or runtime. AST nodes, resolved `describe()`, live API probes. Stable; never inferred.
2. **Derived** — computed from raw by walking AST or analyzing runtime values. Field maps from `parse*()`, auth classification from `sign()`, envelope paths from fetch methods. Every derived field is either **provable from the source** or **explicitly marked unresolvable** (`null` + reason). No silent guesses.
3. **Override** — hand-curated annotations in `priv/overrides/` that fill gaps derivation can't reach (imperative logic, exchange-specific quirks, CCXT bugs). Overrides are validated against runtime behavior where possible and carry explicit reasons. Overrides are a first-class part of the output, not a workaround.

Consumers see the merged result. Provenance is preserved in the JSON so debugging and drift detection remain possible.

## The Honesty Rule (replaces "Extraction vs Interpretation")

**Every value in the output is either provable or explicitly marked unprovable. No silent guesses, ever.**

Learned from Task 46 (url_templates): ~20 rounds of `resolveBaseUrl` fixes couldn't handle CCXT's 4+ `urls.api` shapes. The lesson wasn't "don't derive" — it was "if you can't prove it, say so." `url_prefix` is derived when provable and `null` otherwise; consumers cross-reference raw data to fill the gap or maintain an override.

This rule applies to raw, derived, and override tiers equally:
- Raw: record what CCXT source/runtime actually produced
- Derived: emit a value only when the AST proves it; otherwise `null` with a reason
- Override: must be verified against runtime behavior, or carry `unverified: true` with reason

**Drift is the real enemy.** When CCXT updates upstream, derivation and overrides can rot. Validation (`mix ccxt_extract.validate_*`) and override audits are part of the product, not a nice-to-have.

## The Three-Strikes Derivation Rule

**A derivation patched three times to handle new exchange shapes is no longer derivation — it is interpretation masquerading as extraction. On the third patch, stop.**

Three is deliberate: one patch is learning, two is refinement, three means the AST doesn't encode what you're trying to derive. Task 46 (`resolveBaseUrl`) took ~20 patches before the model was replaced. That was 17 patches of sunk cost.

**On the third patch:**
1. The derivation emits `null` + reason for the failing shape (Honesty Rule still applies — say so when you can't prove it)
2. An override entry in `priv/overrides/<exchange>.json` fills the gap with a `reason`
3. The commit message names which shapes the derivation now owns vs which overrides cover

**Three is the ceiling, not a quota.** On *every* patch, ask: does this extend the derivation's proven territory, or stretch it into a shape it can't generalize? If the second, it is already an override candidate regardless of count. Three-strikes is the backstop for when that judgment fails — which it will.

**Operational signals:**
- Each derivation module declares a running count in its header: `# Patch count: 2/3. Next patch triggers override migration review.`
- PRs that patch an existing derivation state the running count in the description
- Patch #3 is not merged as a patch — it is merged as the migration described above

**Cultural reframe:** a healthy `priv/overrides/` is a sign of maturity, not debt. Phase 9's `drift_audit` reports override count as a *neutral* number, not a problem to shrink. Migrating to override is the expected outcome, not the consolation prize.

The Honesty Rule and Three-Strikes Rule compose: honesty says *declare what you can't prove*; three-strikes says *stop trying to prove it past a point*.

## Tier-Based Scoping

Tier 1 / Tier 2 / DEX (canonical list: `priv/priority_tiers.json`, also stamped as `exchange.tier` in every output JSON since schema 1.8.0) are the exchanges this project commits to *deriving recipes for*. Tier 3 and unclassified exchanges still receive full raw extraction — their AST, resolved `describe()`, and runtime probes are universal — but their derived fields default to `null + reason` until a real consumer surfaces a need.

**Family inheritance.** `priv/priority_tiers.json` lists **roots** only — hand-curated, intentional. Variants (`binance` → `binanceus`, `binancecoinm`, `binanceusdm`; `okx` → `okxus`, `myokx`; `kucoin` → `kucoinfutures`) and aliases (`htx` → `huobi`; `gate` → `gateio`) inherit their root's tier via `priv/discoveries/class_hierarchy.json` at compile time in `CcxtExtract.Tiers`. Inheritance is *provable* from the CCXT class graph, not guessed — honesty rule preserved. `--tier1` scoping therefore pulls in the whole binance family (10 exchanges), not just the root.

This is not a violation of the One Rule. It is an honest application of it: when we don't have evidence a derivation generalizes to the tail, we say so rather than guess. The Three-Strikes Rule still applies — derivations migrate to override on the third patch — but a Tier 3 patch may simply never happen.

**What this means for new derivation work:** if a derivation only matters for Tier 3 / unclassified exchanges (e.g., exotic signing schemes no priority exchange uses), it lives in `ROADMAP.md`'s Superseded / Deferred section until promoted by need.

**Operational tools:** every per-exchange extraction Mix task accepts the full scope flag set (`--tier1 --tier2 --tier3 --dex --all --exchange ID`, combinable, typos fuzzy-suggested). Corpus-level tasks (`setup`, `exchanges`, `base_methods`, top-level `validate`) run unscoped by design — they operate on the CCXT source tree or the base `Exchange.ts` class, where scoping would be meaningless. Pipeline assembly (Task 2), the six OXC batch-A extractors (Task 5 — `classes`, `methods`, `sign_methods`, `handle_errors`, `parse_methods`, `ws_methods`), and the four QuickBEAM extractors (Task 4 — `describe`, `url_templates`, `signing_fixtures`, `load_markets`) are all scope-aware. Aggregate JSON files route writes through `CcxtExtract.AggregateWriter`, which merges scoped runs with existing aggregates and recomputes envelope totals from the final merged entries on every write. Per-exchange-directory tasks (`describe`, `signing_fixtures`, `load_markets`) rebuild their manifest's `exchanges` / `succeeded` list from disk via `TaskScope.rebuild_manifest_exchanges/1` on every write, so manifest state can't drift from on-disk reality. Scope never filters *parsing* of CCXT source — the OXC AST walk is always over all files; filtering applies at the output-merge boundary. `classes.ex` is intentionally an exception: scope flags only stamp `tier_scope`, because `class_hierarchy.json` is load-bearing for `CcxtExtract.Tiers` family inheritance and a partial tree would silently degrade tier expansion. Aliases (`gateio`, `huobi`) inherit their root's tier and appear in scope, but the QuickBEAM-backed extractors skip them (`!d.alias`) — stage-3 guards that depend on per-alias describe files opt into `CcxtExtract.TaskScope.scoped_ids_missing_file/3`'s `exclude_aliases: true` to honour that asymmetry, backed by `CcxtExtract.Aliases`. Tracking: `SCOPED-EXTRACTION-TASKS.md` (Tasks 1–12 complete; see the file for any ongoing drift).

## Consumers Exist — Design For Them

Earlier versions of this doc said "NO consumers yet, don't design output shaped by what a consumer wants." That rule served its purpose (preventing over-fitting during Phase 1-5) and is now **retired**. Consumers exist: ccxt_client (Elixir), a planned Rust client, and future macro-based codegen in multiple languages.

What replaces it:

- Design output so **any language** can consume it without AST walking
- Don't shape output for one specific consumer's internal architecture (e.g. don't mirror ccxt_client's module layout)
- When a consumer requests a field, evaluate whether it belongs in raw, derived, or override — don't reject it as "consumer-specific" if it's knowledge CCXT actually encodes
- If you catch yourself thinking "we probably don't need X" — stop. Extract X.

## Clients

Consumer projects live as **sibling directories** of this repo (independent git repos):

- `../ccxt_client/` — active Elixir consumer (`github.com/ZenHive/ccxt_client`).
  Compile-time macros read `../ccxt_extract/priv/output/*.json` and generate one
  Elixir module per exchange.
- `../ccxt_client_bak/` — archived `.exs`-spec predecessor; porting reference only.

Clients were previously nested under `clients/<lang>/<project>/` (Task 56) but
relocated to siblings (Task 57) because nested CLAUDE.md discovery pulled
ccxt_extract's full context into every client session.

To add a client: clone/create it at `~/_DATA/code/<name>/` and consume JSON from
`../ccxt_extract/priv/output/` or pipe via
`mix ccxt_extract.pipeline --output ../<name>/<path>`.

## Tools

Three Hex packages, zero external toolchains:

### OXC — Parse TypeScript AST (Rust NIF)

```elixir
{:oxc, "~> 0.6"}
```

Parses CCXT TypeScript source into ESTree AST (Elixir maps with atom keys). ~43ms per exchange for the largest files. Extracts:
- Method bodies (sign, parse*, handleErrors, watch*, handle*)
- Class hierarchy (`extends` chains)
- TypeScript type annotations (parameter types, return types)
- describe() object literals (raw, unresolved)

```elixir
source = File.read!("priv/ccxt/ts/src/binance.ts")
{:ok, ast} = OXC.parse(source, "binance.ts")
```

### QuickBEAM — Run CCXT JavaScript Runtime (Zig NIF)

```elixir
{:quickbeam, "~> 0.9"}
```

Loads CCXT's pre-bundled browser build and runs it on the BEAM. All 110 exchanges instantiated in ~13 seconds. Extracts:
- Resolved describe() with full inheritance (`deepExtend` applied)
- Runtime values (`parseNumber`, error class references resolved)
- Live API calls (loadMarkets, fetchTicker — for validation)

```elixir
bundle = File.read!("node_modules/ccxt/dist/ccxt.browser.min.js")
{:ok, rt} = QuickBEAM.start()
# self/window must BE globalThis — set_global with atoms converts to strings
QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
QuickBEAM.set_global(rt, "navigator", %{"userAgent" => "QuickBEAM"})
QuickBEAM.set_global(rt, "location", %{"protocol" => "https:"})
QuickBEAM.call(rt, "eval", [bundle])
```

### npm_ex — Install CCXT Without Node.js

```elixir
{:npm, "~> 0.5"}
```

```bash
mix npm.install ccxt
# node_modules/ccxt/dist/ccxt.browser.min.js is ready for QuickBEAM
```

## CCXT Source

**TypeScript is canonical.** CCXT transpiles TS to Go, Python, PHP, C#. Extracting from TS gives the richest data (type annotations, class hierarchy, no transpilation artifacts).

Two sources needed:
1. **npm install** — provides `node_modules/ccxt/dist/ccxt.browser.min.js` for QuickBEAM
2. **TS source files** — `priv/ccxt/ts/src/*.ts` for OXC parsing

Setup:
```bash
# 1. Browser bundle (for QuickBEAM runtime)
mix npm.install ccxt

# 2. TypeScript source (for OXC AST parsing)
git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt
cd priv/ccxt && git sparse-checkout set ts/src package.json
```

### Source Layout

```
priv/ccxt/ts/src/              # 110 REST exchange classes; base Exchange lives in base/
priv/ccxt/ts/src/pro/          # ~78 WS exchange implementations
priv/ccxt/ts/src/abstract/     # Generated interface files — typed API method signatures per exchange
priv/ccxt/ts/src/base/         # Base Exchange class (~9k lines) + utilities, errors, types
node_modules/ccxt/dist/        # Pre-built browser bundle for QuickBEAM
```

## Current Output Schema (exchange_v1.json)

**Full schema reference:** See [SCHEMA.md](SCHEMA.md) for field-level definitions, type shapes, role/sentinel classification, and version history.

Per-exchange JSON has three top-level sections:

```
{
  "schema_version": "1.8.0",
  "ccxt_version": "4.x.x",
  "exchange": { id, name, alias, tier },  # tier ∈ "tier1" | "tier2" | "tier3" | "dex" | "unclassified" (schema 1.8.0)
  "runtime": {
    "describe": { ... },          # Resolved describe() via QuickBEAM (has, api, exceptions, etc.)
    "markets": { ... },           # loadMarkets() data (symbols, precision, limits, fees)
    "symbol_patterns": { ... },   # Derived per-type formatting rules (separator, case, suffix, anomalies)
    "url_templates": { ... }      # Per-section URL templates from sign() (base_url, sample_path, resolved_url)
  },
  "structure": {
    "class_info": { ... },        # Class name, parent, file path
    "methods": { ... },           # REST + WS method inventory (names, async, params)
    "sign_method": { ... },       # sign() AST body
    "authenticated_sections": [...], # API sections requiring auth (from sign() AST)
    "handle_errors": { ... },     # handleErrors() AST body
    "parse_methods": { ... },     # parse*() AST bodies
    "ws_methods": { ... },        # watch*/handle* WS AST bodies
    "interface_signatures": { ... }, # Typed API method signatures from abstract/*.ts
    "pagination": { ... },        # Per-method pagination strategy and parameters
    "overrides": { ... },         # Methods overridden vs parent class
    "unified_endpoints": { ... }  # Unified method → interface method mappings
  }
}
```

All keys always present (null when not applicable). Two-state: data or null.

## Extraction Gaps (vs Go Extractor)

These categories exist in the Go extractor but not yet in ccxt_extract. All are extractable from TS source — see Phase 6 in ROADMAP.md:

| Category | Source | Status |
|----------|--------|--------|
| **Interface signatures** | `abstract/*.ts` — per-exchange typed API method definitions | ✅ Task 30 |
| **Auth assembly** | Decomposed signing steps from `sign()` AST | Task 33 |
| **Pagination strategies** | `fetchPaginatedCall*` patterns in method bodies | ✅ Task 32 |
| **Base normalizers** | `parse*()`, `safe*()` methods in `base/Exchange.ts` | ✅ Task 31 |
| **Handler routing** | Method → handler dispatch tables | Task 34 |

Consumer priority: interface signatures > auth assembly > pagination > base normalizers > handler routing.

## Output Requirements

- **JSON-native types only**: strings, numbers, booleans, arrays, objects, null
- **No Elixir-specific types**: no atoms, no tuples, no structs
- **Per-exchange files**: one JSON file per exchange
- **Deterministic**: same CCXT version + same extraction code = identical output
- **Complete**: if CCXT knows it, we extract it
- **Include a schema/format spec**: document the output format so any language can consume it

## Development Commands

```bash
mix deps.get
mix compile
mix test.json --quiet              # AI-friendly test output
mix dialyzer.json --quiet          # AI-friendly dialyzer output
mix credo --strict --format json   # Static analysis
mix doctor                         # Documentation quality
mix format                         # Format code (Styler)

# Setup CCXT
mix ccxt_extract.setup             # Install/verify CCXT sources
mix ccxt_extract.contract_test     # Cross-field semantic invariants over emitted JSON
mix ccxt_extract.contract_test --strict  # Non-zero exit on any finding (for CI)
mix ccxt_extract.update            # Full re-extract: setup → extractors → pipeline → validate → contract_test → analytics
mix ccxt_extract.update --latest   # Update to latest CCXT version
mix ccxt_extract.update --skip-setup  # Re-run pipeline + validate + contract_test + analytics (skips QuickBEAM analytics)

# Scope a run (combinable; default is all 110 when no flag given)
mix ccxt_extract.update --tier1 --dex                   # Tier 1 + DEX (14 exchanges after family expansion)
mix ccxt_extract.update --exchange binance,deribit      # Single-exchange subset (repeatable / comma-split)
mix ccxt_extract.update --tier1 --exchange hyperliquid  # Mixed tier + individual
mix ccxt_extract.update --all --force                   # Bypass git-status safety rail (see note below)

# After extraction, review and commit changes
git diff priv/discoveries/                    # See what changed in discovery data
git add priv/discoveries/ priv/output/        # Commit updated extraction data

# Run examples
mix run examples/1_parse_exchange.exs binance
mix run examples/3_quickbeam_describe.exs binance
```

`mix ccxt_extract.update` aborts if `priv/output/` or `priv/discoveries/` has
uncommitted changes — commit or stash first, or pass `--force` to bypass the
rail. See "Tier-Based Scoping" above for the full scope flag semantics,
combinability rules, and family expansion (e.g., `--tier1` pulls in the entire
binance family via `class_hierarchy.json`).

## Examples

The `examples/` directory contains working scripts. The numbered ones demonstrate OXC and QuickBEAM — run them to understand the tools. The `compare_*` scripts measure extraction coverage against other extractors.

### Tool Demos
```bash
mix run examples/1_parse_exchange.exs binance    # OXC: parse TS → ESTree AST
mix run examples/2_extract_describe.exs binance  # OXC: extract describe() from AST
mix run examples/3_quickbeam_describe.exs binance # QuickBEAM: resolved describe() at runtime
mix run examples/4_quickbeam_fetch_ticker.exs     # QuickBEAM: live API call
mix run examples/5_family_variants.exs            # Family analysis (binance → binanceus, etc.)
```

### Comparison Scripts
```bash
# Requires: ../ccxt_go_extractor built (go build -o ccxt-extract ./cmd/ccxt-extract)
mix run examples/compare_go_extractor.exs   # Compare vs Go extractor — shows what each has

# Requires: ../ccxt_client/priv/specs/extracted/ (old ccxt_client .exs specs)
mix run examples/compare_old_counts.exs     # Data volume comparison (endpoints, has, exceptions)
mix run examples/compare_old_specs.exs      # Key-by-key coverage validation
```

## How CCXT Works: Transpilation Architecture

CCXT is written in TypeScript and transpiled to Go, Python, PHP, C#, and Java. Understanding their pipeline explains why TS is the canonical source and why we extract data rather than transpile code.

**Their three-layer system:**

1. **TypeScript compiler** — parses exchange TS source into a TS AST. (We use OXC instead — 43ms vs the TS compiler which is too heavy for in-process use.)

2. **ast-transpiler** (`ccxt/ast-transpiler` on npm) — their own AST-to-code library. A `BaseTranspiler` with 152 methods walks the AST and prints target language code. Six language backends override ~50-90 methods each for language-specific idioms (Go needs channels for async, structs for classes, explicit types; Python needs `self.`, snake_case, `isinstance`).

3. **Regex post-processing** (the `build/*.ts` files) — thousands of lines of regex substitutions per language target. Handles CCXT-specific naming, crypto function mapping, method name conversion, formatting. 3,161 lines for Python/PHP, 2,734 for Go, 1,472 for C#.

**Why we chose a different path:**

CCXT transpiles *code* (TS method body → Go/Python method body). We extract *data* — the AST itself as JSON, plus runtime-resolved values from QuickBEAM. This means:

- Consumers decide per-method whether to pattern-match the AST or transpile it
- The output is language-agnostic (JSON, not Elixir/Rust/Go code)
- No regex post-processing layer needed
- The raw AST preserves all information; transpilation is lossy

**Do NOT** attempt to build a transpiler, write an Elixir backend for ast-transpiler, or convert AST nodes to Elixir code. That's a consumer concern. This repo extracts data.

## Git Commit Configuration

**Configured**: 2026-03-28

### Commit Message Format

**Format**: imperative-mood

#### Imperative Mood Template
```
<description>
```
Start with imperative verb: Add, Update, Fix, Remove, etc.

## Reference Exchanges for Integration Testing

From ccxt_ex priority tiers. All integration tests with known-exchange assertions must cover these:

**Tier 1** (must have): `binance`, `bybit`, `okx`, `deribit`, `coinbaseexchange`
**Tier 2** (valuable): `kraken`, `kucoin`, `gate`, `htx`, `bitmex`
**DEX** (selected): `hyperliquid`, `aster`, `lighter`

These cover different family shapes: families with variants (binance has binanceus/binancecoinm/binanceusdm, okx has okxus, kucoin has kucoinfutures), families with aliases (htx/huobi, gate/gateio), standalone exchanges (bybit, kraken, deribit, bitmex, coinbaseexchange), and DEX exchanges (hyperliquid, aster, lighter).

## Extraction Data

Both `priv/discoveries/` (intermediate discovery JSON) and `priv/output/` (final
per-exchange JSON) are committed. Cached integration tests read directly from
`priv/discoveries/` — no separate fixture copy.

**`load_markets` is live-API data.** Unlike OXC-based extractors (deterministic from
source), `mix ccxt_extract.load_markets` calls real exchange APIs via QuickBEAM.
Results vary by network/geo/time — exchanges go down, get geo-blocked, or start
requiring auth. The `--skip-setup` flag on `mix ccxt_extract.update` skips stages 1-3
(setup + all extractors) and QuickBEAM-dependent analytics (describe_keys, describe_key_analysis).

After running `mix ccxt_extract.update`, review diffs and commit. The output JSON
is the primary product of this repo — consumers can clone and use it without
installing Elixir.

## What This Repo Is NOT

- Not a trading library (no HTTP clients, no signing, no WebSocket)
- Not an Elixir library with runtime modules (extraction runs at build time or as a tool)
- Not coupled to any specific consumer
- Not a port or wrapper of ccxt_ex (that project exists separately)
- Not a transpiler — we extract data (AST + runtime values), not code
