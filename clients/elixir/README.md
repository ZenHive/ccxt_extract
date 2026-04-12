# Elixir clients

Elixir consumers of ccxt_extract JSON. Each project under this directory is its
own independent git repository (see [../README.md](../README.md) for the
nested-but-separate model).

## Projects

- **[ccxt_client/](ccxt_client/)** — `github.com/ZenHive/ccxt_client`. Compile-time
  macros read `priv/output/*.json` and generate one Elixir module per exchange.
  Relocated here from `../ccxt_client/` in Task 56.

## Adding another Elixir client

1. `cd clients/elixir && git clone <repo>` (or `git init <name>`)
2. Consume JSON from `../../../priv/output/` or pipe output via
   `mix ccxt_extract.pipeline --output clients/elixir/<name>/<path>`
3. Already covered by ccxt_extract's `.gitignore` (`/clients/*/*/`) — no changes needed
