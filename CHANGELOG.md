# Changelog

Completed roadmap tasks. For upcoming work, see [ROADMAP.md](ROADMAP.md).

---

## [Unreleased]

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
