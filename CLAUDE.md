# CLAUDE.md

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
QuickBEAM.set_global(rt, "self", :global_this)
QuickBEAM.set_global(rt, "window", :global_this)
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
cd priv/ccxt && git sparse-checkout set ts/src
```

### Source Layout

```
priv/ccxt/ts/src/              # 111 REST exchange classes + base Exchange
priv/ccxt/ts/src/pro/          # ~78 WS exchange implementations
priv/ccxt/ts/src/abstract/     # Type definitions per exchange
priv/ccxt/ts/src/base/         # Base Exchange class + utilities
node_modules/ccxt/dist/        # Pre-built browser bundle for QuickBEAM
```

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
mix npm.install ccxt               # Browser bundle for QuickBEAM
# Then clone TS source (see above)

# Run examples
mix run examples/1_parse_exchange.exs binance
mix run examples/3_quickbeam_describe.exs binance
```

## Examples

The `examples/` directory contains 5 working scripts that demonstrate OXC and QuickBEAM. Run them to understand the tools before building extraction logic. They are the quickest way to see what data is available.

## What This Repo Is NOT

- Not a trading library (no HTTP clients, no signing, no WebSocket)
- Not an Elixir library with runtime modules (extraction runs at build time or as a tool)
- Not coupled to any specific consumer
- Not a port or wrapper of ccxt_ex (that project exists separately)
