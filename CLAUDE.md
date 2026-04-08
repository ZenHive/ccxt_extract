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

Extract **everything** CCXT knows about 111+ cryptocurrency exchanges into language-agnostic data.

Output: plain maps, JSON-serializable. No Elixir atoms, no structs, no language-specific types. The output must be consumable by any language — Elixir, Rust (`serde_json::from_str`), Python, Go, whatever. Design as if you don't know who the consumer is, because you don't.

## The One Rule

**Extract EVERYTHING. Never filter.**

CCXT has 7+ years of accumulated exchange knowledge. Every field exists for a reason. If CCXT's `describe()` returns 32 keys, extract 32 keys. If an exchange has 166 methods, catalog 166 methods. Storage is cheap; missing data is expensive. You cannot know what a future consumer will need.

## Anti-Bias Rule

This library has **NO consumers yet.** Do not design output shaped by what you think a trading library, a code generator, or a dashboard might need. Extract what CCXT knows, organized by what CCXT knows — not by what you imagine someone wants.

If you catch yourself thinking "we probably don't need X" — stop. Extract X.

## Tools

Three Hex packages, zero external toolchains:

### OXC — Parse TypeScript AST (Rust NIF)

```elixir
{:oxc, "~> 0.5"}
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
{:quickbeam, "~> 0.8"}
```

Loads CCXT's pre-bundled browser build and runs it on the BEAM. All 111 exchanges instantiated in ~13 seconds. Extracts:
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
priv/ccxt/ts/src/              # 111 REST exchange classes + base Exchange
priv/ccxt/ts/src/pro/          # ~78 WS exchange implementations
priv/ccxt/ts/src/abstract/     # Generated interface files — typed API method signatures per exchange
priv/ccxt/ts/src/base/         # Base Exchange class (~9k lines) + utilities, errors, types
node_modules/ccxt/dist/        # Pre-built browser bundle for QuickBEAM
```

## Current Output Schema (exchange_v1.json)

Per-exchange JSON has three top-level sections:

```
{
  "schema_version": "1.0.0",
  "ccxt_version": "4.x.x",
  "exchange": { id, name, alias },
  "runtime": {
    "describe": { ... },          # Resolved describe() via QuickBEAM (has, api, exceptions, etc.)
    "markets": { ... },           # loadMarkets() data (symbols, precision, limits, fees)
    "symbol_patterns": { ... }    # Derived per-type formatting rules (separator, case, suffix, anomalies)
  },
  "structure": {
    "class_info": { ... },        # Class name, parent, file path
    "methods": { ... },           # REST + WS method inventory (names, async, params)
    "sign_method": { ... },       # sign() AST body
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
mix ccxt_extract.update            # Full re-extract: setup → extractors → pipeline → validate → analytics
mix ccxt_extract.update --latest   # Update to latest CCXT version
mix ccxt_extract.update --skip-setup  # Re-run pipeline + validate + analytics (skips QuickBEAM analytics)

# After extraction, review and commit changes
git diff priv/discoveries/                    # See what changed in discovery data
git add priv/discoveries/ priv/output/        # Commit updated extraction data

# Run examples
mix run examples/1_parse_exchange.exs binance
mix run examples/3_quickbeam_describe.exs binance
```

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
