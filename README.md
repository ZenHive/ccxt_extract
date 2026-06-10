# CcxtExtract

Extract CCXT exchange knowledge into language-agnostic JSON using:

- `QuickBEAM` for resolved runtime data from the CCXT browser bundle
- `OXC` for structural TypeScript AST data from CCXT source files

## Setup

Fresh clones bootstrap with a single Mix command — `mix ccxt_extract.setup`
auto-detects when `priv/ccxt/ts/src/` is missing and sparse-clones the
CCXT TypeScript source itself (depth 1, `ts/src` only), pinned to the
version recorded in `priv/ccxt_version.json` by default.

```bash
mix setup
```

`mix setup` is an alias for `deps.get` + `ccxt_extract.update`
(`ccxt_extract.update` internally runs `ccxt_extract.setup` in Stage 1,
so it's not listed separately). It:

- resolves Elixir dependencies
- installs CCXT from npm
- copies the browser bundle to `priv/ccxt_bundle.js`
- verifies QuickBEAM can load CCXT
- verifies OXC can parse a CCXT exchange file
- records version metadata in `priv/ccxt_version.json`
- runs every extractor and the assembly pipeline to materialize
  `priv/discoveries/*` and `priv/output/<id>.json`

The derived corpus (`priv/output/` and `priv/discoveries/*`) is **not
committed** to git — too large, too churny, regenerated per CCXT
release. The one tracked exception is
`priv/discoveries/class_hierarchy.json`, which
`lib/ccxt_extract/tiers.ex` reads at compile time via `@external_resource`.

**Just the toolchain, no corpus?** Skip `mix setup` and run
`mix ccxt_extract.setup` directly — it performs the npm install,
bundle copy, and version recording without the (slow) extraction pass.

**`mix test` refuses to start without the corpus.** `test/test_helper.exs`
checks for sentinel files (`priv/discoveries/exchanges.json`,
`priv/discoveries/class_hierarchy.json`, `priv/output/binance.json`) and
halts with setup instructions if any are missing — rather than letting
cached integration tests fail later with cryptic `File.read!/1` errors.

## Examples

```bash
mix ccxt_extract.exchanges
mix run examples/3_quickbeam_describe.exs
mix run examples/1_parse_exchange.exs binance
```

## Priority Tiers

Each output JSON carries `exchange.tier` (schema 1.8.0+) — one of `"tier1"`, `"tier2"`, `"tier3"`, `"dex"`, or `"unclassified"`. The canonical **roots** list is hand-curated in [`priv/priority_tiers.json`](priv/priority_tiers.json); variants and aliases inherit their root's tier via `priv/discoveries/class_hierarchy.json` (e.g. `binanceus`, `binancecoinm`, `binanceusdm` → `tier1`; `huobi`, `gateio` → `tier3`).

Raw extraction runs for all 110 exchanges. **Derivation** effort (signing recipes, fee schedules, error handlers) is scoped (since 2026-05-20) to the **7-exchange option-seller set** — Tier 1 (`binance` + `binanceusdm`, `bybit`, `okx`, `deribit`) plus priority DEX (`hyperliquid`, `derive`). Tier 2 is intentionally empty; Tier 3 and unclassified exchanges get `null + reason` for derived fields until a priority consumer surfaces a need. The scope is a movable slider — see `CLAUDE.md` §"Tier-based scoping (philosophy)" for the re-add procedure and the frozen pre-narrow curation.

Every per-exchange extraction Mix task accepts the canonical scope flag set — `--tier1 --tier2 --tier3 --dex --all --exchange ID` (combinable; `--exchange` is repeatable and accepts comma-split IDs; unknown IDs abort with fuzzy suggestions). Corpus-level tasks (`setup`, `exchanges`, `base_methods`, top-level `validate`) run unscoped by design. Tier flags expand to the **whole family** — `--tier1` pulls in the binance variants alongside `binance`:

```bash
mix ccxt_extract.load_markets --tier1 --dex
mix ccxt_extract.contract_test --tier1 --dex
mix ccxt_extract.update --tier1 --dex                    # the 7-exchange derivation-scoped set
mix ccxt_extract.update --exchange binance,deribit       # single-exchange subset (repeatable or comma-split)
mix ccxt_extract.update --tier1 --exchange hyperliquid   # mixed tier + individual
```

Default (no scope flag) is all 110 exchanges. OXC *parsing* always walks all CCXT `.ts` files; scope applies at the output-merge boundary. `classes.ex` is a documented exception — scope flags only stamp `tier_scope` because `class_hierarchy.json` is load-bearing for family inheritance. Aggregate writes merge scoped runs with existing on-disk aggregates and recompute envelope totals from the final merged entries, so successive scoped runs accumulate without drift.

`mix ccxt_extract.update` has a git-status safety rail for tracked corpus paths that protects against scoped runs overwriting in-flight work. Since `priv/output/` and most of `priv/discoveries/` are gitignored, the rail is effectively inert for day-to-day regeneration — `git status` doesn't see those files, so no "uncommitted changes" abort fires. It still protects `priv/discoveries/class_hierarchy.json`, the one tracked corpus file whose drift between runs is worth a human review.

Pass `--force` to bypass the rail. The rail is automatically skipped when `--output DIR` is set — external target dirs are not expected to be git repos, and writes go to `<DIR>/output/` + `<DIR>/discoveries/` under a per-run `:priv_dir_override` so the repo's own `priv/` is untouched.

## Signing Fixtures

`mix ccxt_extract.signing_fixtures` generates language-agnostic signing test
vectors by calling CCXT JS's `exchange.sign()` under frozen credentials,
timestamps, and nonces. One JSON file per non-alias exchange lands in
`priv/fixtures/signing/<id>.json`, plus `_manifest.json`.

These fixtures are the handoff between CCXT truth and any port (Elixir, Rust,
Go, Python). Consumers replay the frozen inputs against their own signing
implementation and assert byte-equal output on `url`, `method`, `headers`,
`body`.

**Frozen environment:** `Date.now() = 1700000000000`, `ex.nonce() = 1700000000`,
`Math.random() = 0.42`, `crypto.getRandomValues` + `ex.randomBytes` /
`ex.uuid*` return zero bytes. Credentials are conventional placeholders
(`TEST_API_KEY`, 32-zero-byte base64 secret, `TEST_PASSPHRASE`, etc.).

**Re-run after upgrading CCXT** (`mix ccxt_extract.setup --latest`). Output
is byte-identical across runs except the top-level `generated_at` field.

Fixture schema (per exchange):

```json
{
  "exchange": "bybit",
  "ccxt_version": "4.x.y",
  "generated_at": "2026-...",
  "credentials": { "apiKey": "TEST_API_KEY", "secret": "<base64>", ... },
  "frozen": { "timestamp_ms": 1700000000000, "nonce": 1700000000 },
  "cases": [
    { "name": "public_get_ticker",  "input": {...}, "output": {...} },
    { "name": "private_get_balance", "input": {...}, "output": {...} },
    { "name": "private_post_order",  "input": {...}, "output": {...} }
  ],
  "skipped": [{ "name": "...", "reason": "..." }]
  // `errors` key is only present when instantiation or describe() fails
}
```

Inside `input` and `output`, original CCXT key casing is preserved
(`apiKey`, `X-BAPI-SIGN`, `OK-ACCESS-TIMESTAMP`, etc.) — that IS the wire
contract. `cases` records successful signs; `skipped` records per-case
failures with reasons; `errors` records instantiation / describe-level
failures.
