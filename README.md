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
