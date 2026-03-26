# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON data, consumable by any programming language.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

---

## Phase 1: Setup & Discovery [D:3/B:9/U:10 -> Eff:3.17]

> Before building anything, understand what CCXT actually contains. Run the example scripts. Catalog everything.

### Tasks

- [x] **Task 1: CCXT source setup** — Install CCXT via `mix npm.install ccxt` and clone TS source via sparse checkout. Verify both paths work: QuickBEAM can load the browser bundle, OXC can parse TS files. Create a mix task (`mix ccxt_extract.setup`) that does both.

- [ ] **Task 2: Exchange inventory** — Use QuickBEAM to instantiate all exchanges and list them. Record: id, name, certified, pro (WS support), class hierarchy. Use OXC to find all TS files and their class `extends` chains. How many exchanges? How many have WS? How many are variants of another?

- [ ] **Task 3: describe() key inventory** — For every exchange, extract the full `describe()` via QuickBEAM. What are ALL the top-level keys? Which keys appear on every exchange? Which are exchange-specific? How deep do the nested structures go? Don't assume you know — catalog what's actually there.

- [ ] **Task 4: Method inventory** — For every exchange, use OXC to extract all method names, parameter names, TypeScript types, async/sync, and statement counts. How many methods does each exchange have? What are the common methods across all exchanges? What are unique methods? Catalog the parse*, watch*, handle*, fetch*, create*, cancel* families.

- [ ] **Task 5: Document discoveries** — Write a DISCOVERIES.md with what was found. This becomes the design input for later phases. Include: key counts, method counts, family groupings, inheritance patterns, anything surprising.

- [x] **Task 18: Fix QuickBEAM browser global pattern in examples** [D:1/B:3/U:5 → Eff:4.00] [P]
      Examples 3 and 4 use `set_global(rt, "self", :global_this)` which doesn't create true identity with globalThis. Replace with the working `QuickBEAM.eval` pattern for setting browser globals. Discovered during Task 1.

---

## Phase 2: Runtime Extraction — QuickBEAM [D:5/B:9/U:9 -> Eff:1.80]

> QuickBEAM runs the full CCXT runtime. Use it for everything that requires inheritance resolution, runtime computation, or actual API data.

### Tasks

- [ ] **Task 6: Full describe() extraction** — Extract the complete `describe()` for all exchanges via QuickBEAM. Every key, every nested value. Save as one JSON file per exchange. This is the most important extraction — describe() contains has, exceptions, features, urls, api, fees, timeframes, options, commonCurrencies, precisionMode, paddingMode, requiredCredentials, and more.

- [ ] **Task 7: Exchange family analysis** — Group exchanges by inheritance. Which exchanges share a base class? What does each variant override? Use both QuickBEAM (compare describe() output between parent and child) and OXC (compare method lists). Document the family tree.

- [ ] **Task 8: loadMarkets() extraction** — For exchanges with public API access (no auth needed), run `loadMarkets()` via QuickBEAM. Extract market listings: symbol formats, precision, limits, market types (spot, swap, future, option), fee structures. This is live API data — may need rate limiting.

---

## Phase 3: Structural Extraction — OXC AST [D:7/B:9/U:8 -> Eff:1.21]

> OXC parses TypeScript source into AST. Use it for structural data that QuickBEAM can't provide: method bodies, signing logic, error handling patterns, field mappings. **Output raw ESTree AST as JSON** — don't pre-classify or reduce to patterns. Consumers decide whether to pattern-match the AST (parameterized patterns) or transpile it (code generation). The AST is the data.

### Tasks

- [ ] **Task 9: sign() method extraction** — Extract the `sign()` method body as raw ESTree AST (JSON) for every exchange. This is how each exchange authenticates API requests. Output the full AST — don't classify into patterns, don't pre-categorize. Consumers decide whether to pattern-match (e.g., "9 signing patterns") or transpile the AST into target language code. The raw AST is the data.

- [ ] **Task 10: handleErrors() extraction** — Extract `handleErrors()` body as raw ESTree AST for every exchange. How does each exchange map HTTP responses to error types? Output the full method AST alongside the exceptions from describe(). Don't reduce to a lookup table — the AST captures conditional logic, fallthrough, and edge cases that a table would lose.

- [ ] **Task 11: parse*() method extraction** — Extract all `parse*` method bodies as raw ESTree AST (parseTicker, parseOrder, parseTrade, parseBalance, etc.). These contain field-by-field mappings from exchange-specific format to CCXT's unified format. Output the full AST per method. Consumers can extract mapping tables from the AST, or transpile the method body directly — that's their choice, not ours.

- [ ] **Task 12: WS method extraction** — Extract all `watch*` and `handle*` methods from `pro/*.ts` as raw ESTree AST. These define WebSocket subscription and message handling. Output full method ASTs — channel names, message formats, and subscription logic are all embedded in the code and should be preserved structurally.

- [ ] **Task 13: Class hierarchy and overrides** — Build the complete class hierarchy tree. For each exchange that extends another, identify exactly which methods are overridden and include the override's AST. This tells consumers both what's unique about each exchange AND gives them the code to work with.

---

## Phase 4: Output Format & Validation [D:5/B:8/U:9 -> Eff:1.70]

> Design the output format AFTER you know what data exists. Not before.

### Tasks

- [ ] **Task 14: Design output schema** — Based on everything discovered in Phases 1-3, design a JSON schema for the per-exchange output. The schema should reflect CCXT's actual structure, not any consumer's needs. Use JSON-native types only (strings, numbers, booleans, arrays, objects, null). Include a formal JSON Schema spec so any language can validate. The output has two layers: (1) resolved runtime data from QuickBEAM (describe, markets — values), and (2) raw ESTree AST from OXC (method bodies — code as data). Both are JSON. Consumers choose per-method whether to interpret the AST as patterns or transpile it.

- [ ] **Task 15: Full extraction pipeline** — Build the pipeline that runs QuickBEAM + OXC extraction for all exchanges and writes per-exchange JSON files. Should be runnable via a single mix task. Deterministic: same input = same output.

- [ ] **Task 16: Validation** — Round-trip validate: load each JSON file, compare key sections against QuickBEAM runtime output. Ensure nothing was lost or transformed incorrectly. Report any discrepancies.

- [ ] **Task 17: Coverage report** — For each exchange, report what was extracted and what wasn't. Are there describe() keys we missed? Methods we didn't catalog? Any exchange that failed extraction? The goal is 100% coverage of what CCXT knows.

---

## Notes

- Tasks are written as prompts for Claude to implement — explore the codebase and discover the right approach
- Phase order matters: Discovery first, then runtime extraction, then structural, then output format
- The output format in Phase 4 is designed AFTER Phases 1-3 reveal what data actually exists
- See `examples/` for working OXC and QuickBEAM scripts to understand the tools
- **AST as data, not as code**: CCXT's own transpiler (ast-transpiler + regex post-processing) converts TS AST → target language code. We take a different approach: extract the AST as JSON data. This gives consumers maximum flexibility — they can pattern-match it (parameterized patterns like "9 signing types"), transpile it (AST → Elixir/Rust code), or analyze it (dashboards, capability discovery). The extraction layer doesn't decide which strategy is right.
- **Two-layer output**: QuickBEAM gives resolved values (what an exchange IS — config, capabilities, markets). OXC gives structural AST (what an exchange DOES — signing logic, parsing logic, error handling). Both are JSON. Both are complete. Together they capture everything CCXT knows.
