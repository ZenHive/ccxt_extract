# CcxtExtract

Extract CCXT exchange knowledge into language-agnostic JSON using:

- `QuickBEAM` for resolved runtime data from the CCXT browser bundle
- `OXC` for structural TypeScript AST data from CCXT source files

## Setup

Install dependencies and prepare CCXT:

```bash
mix deps.get
mix ccxt_extract.setup
```

`mix ccxt_extract.setup`:

- installs CCXT from npm
- copies the browser bundle to `priv/ccxt_bundle.js`
- verifies QuickBEAM can load CCXT
- verifies OXC can parse a CCXT exchange file
- records version metadata in `priv/ccxt_version.json`

For TypeScript source extraction, provide a CCXT checkout at `priv/ccxt`:

```bash
git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt
cd priv/ccxt && git sparse-checkout set ts/src
```

Optional: include `package.json` too if you want setup to verify the TypeScript
source version against the npm bundle:

```bash
git sparse-checkout add package.json
```

## Examples

```bash
mix ccxt_extract.exchanges
mix run examples/3_quickbeam_describe.exs
mix run examples/1_parse_exchange.exs binance
```

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
