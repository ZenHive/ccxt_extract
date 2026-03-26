# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON data, consumable by any programming language.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

---

## Phase 1: Setup & Discovery [D:3/B:9/U:10 -> Eff:3.17]

> Before building anything, understand what CCXT actually contains. Run the example scripts. Catalog everything.

### Tasks

- [ ] **Task 1: CCXT source setup** — Install CCXT via `mix npm.install ccxt` and clone TS source via sparse checkout. Verify both paths work: QuickBEAM can load the browser bundle, OXC can parse TS files. Create a mix task (`mix ccxt_extract.setup`) that does both.

- [ ] **Task 2: Exchange inventory** — Use QuickBEAM to instantiate all exchanges and list them. Record: id, name, certified, pro (WS support), class hierarchy. Use OXC to find all TS files and their class `extends` chains. How many exchanges? How many have WS? How many are variants of another?

- [ ] **Task 3: describe() key inventory** — For every exchange, extract the full `describe()` via QuickBEAM. What are ALL the top-level keys? Which keys appear on every exchange? Which are exchange-specific? How deep do the nested structures go? Don't assume you know — catalog what's actually there.

- [ ] **Task 4: Method inventory** — For every exchange, use OXC to extract all method names, parameter names, TypeScript types, async/sync, and statement counts. How many methods does each exchange have? What are the common methods across all exchanges? What are unique methods? Catalog the parse*, watch*, handle*, fetch*, create*, cancel* families.

- [ ] **Task 5: Document discoveries** — Write a DISCOVERIES.md with what was found. This becomes the design input for later phases. Include: key counts, method counts, family groupings, inheritance patterns, anything surprising.

---

## Phase 2: Runtime Extraction — QuickBEAM [D:5/B:9/U:9 -> Eff:1.80]

> QuickBEAM runs the full CCXT runtime. Use it for everything that requires inheritance resolution, runtime computation, or actual API data.

### Tasks

- [ ] **Task 6: Full describe() extraction** — Extract the complete `describe()` for all exchanges via QuickBEAM. Every key, every nested value. Save as one JSON file per exchange. This is the most important extraction — describe() contains has, exceptions, features, urls, api, fees, timeframes, options, commonCurrencies, precisionMode, paddingMode, requiredCredentials, and more.

- [ ] **Task 7: Exchange family analysis** — Group exchanges by inheritance. Which exchanges share a base class? What does each variant override? Use both QuickBEAM (compare describe() output between parent and child) and OXC (compare method lists). Document the family tree.

- [ ] **Task 8: loadMarkets() extraction** — For exchanges with public API access (no auth needed), run `loadMarkets()` via QuickBEAM. Extract market listings: symbol formats, precision, limits, market types (spot, swap, future, option), fee structures. This is live API data — may need rate limiting.

---

## Phase 3: Structural Extraction — OXC AST [D:7/B:9/U:8 -> Eff:1.21]

> OXC parses TypeScript source into AST. Use it for structural data that QuickBEAM can't provide: method bodies, signing logic, error handling patterns, field mappings.

### Tasks

- [ ] **Task 9: sign() method extraction** — Extract the `sign()` method body AST for every exchange. This is how each exchange authenticates API requests. Classify what you find — don't start with categories, let the data reveal the patterns. What hash algorithms? Where does the signature go (header, query, body)? What gets signed?

- [ ] **Task 10: handleErrors() extraction** — Extract `handleErrors()` for every exchange. How does each exchange map HTTP responses to error types? What error codes exist? What broad patterns? Combine with exceptions from describe().

- [ ] **Task 11: parse*() method extraction** — Extract all `parse*` method bodies (parseTicker, parseOrder, parseTrade, parseBalance, etc.). These contain field-by-field mappings from exchange-specific format to CCXT's unified format. Extract the mapping tables: which exchange field maps to which unified field, with what transformation.

- [ ] **Task 12: WS method extraction** — Extract all `watch*` and `handle*` methods from `pro/*.ts`. These define WebSocket subscription and message handling. What channels? What message formats? How does subscription work for each exchange?

- [ ] **Task 13: Class hierarchy and overrides** — Build the complete class hierarchy tree. For each exchange that extends another, identify exactly which methods are overridden. This tells you what's unique about each exchange vs. inherited from its parent.

---

## Phase 4: Output Format & Validation [D:5/B:8/U:9 -> Eff:1.70]

> Design the output format AFTER you know what data exists. Not before.

### Tasks

- [ ] **Task 14: Design output schema** — Based on everything discovered in Phases 1-3, design a JSON schema for the per-exchange output. The schema should reflect CCXT's actual structure, not any consumer's needs. Use JSON-native types only (strings, numbers, booleans, arrays, objects, null). Include a formal JSON Schema spec so any language can validate.

- [ ] **Task 15: Full extraction pipeline** — Build the pipeline that runs QuickBEAM + OXC extraction for all exchanges and writes per-exchange JSON files. Should be runnable via a single mix task. Deterministic: same input = same output.

- [ ] **Task 16: Validation** — Round-trip validate: load each JSON file, compare key sections against QuickBEAM runtime output. Ensure nothing was lost or transformed incorrectly. Report any discrepancies.

- [ ] **Task 17: Coverage report** — For each exchange, report what was extracted and what wasn't. Are there describe() keys we missed? Methods we didn't catalog? Any exchange that failed extraction? The goal is 100% coverage of what CCXT knows.

---

## Notes

- Tasks are written as prompts for Claude to implement — explore the codebase and discover the right approach
- Phase order matters: Discovery first, then runtime extraction, then structural, then output format
- The output format in Phase 4 is designed AFTER Phases 1-3 reveal what data actually exists
- See `examples/` for working OXC and QuickBEAM scripts to understand the tools
