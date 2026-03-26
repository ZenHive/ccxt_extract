defmodule CcxtExtract do
  @moduledoc """
  Language-agnostic extraction of CCXT exchange knowledge.

  Uses OXC (Rust NIF) to parse CCXT TypeScript source and QuickBEAM (Zig NIF)
  to run the full CCXT JavaScript runtime on the BEAM. Extracts everything
  CCXT knows about 111+ cryptocurrency exchanges into plain maps/JSON.

  ## Tools

  - **OXC** — Parse TypeScript into ESTree AST. Method bodies, class hierarchy,
    type annotations. ~43ms per exchange.
  - **QuickBEAM** — Run CCXT's browser bundle on the BEAM. Resolved describe()
    with full inheritance, runtime values. All exchanges in ~13 seconds.
  - **npm_ex** — Install CCXT from npm without Node.js.

  ## Setup

      mix deps.get
      mix npm.install ccxt

  For TypeScript source (OXC parsing), clone CCXT with sparse checkout:

      git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt
      cd priv/ccxt && git sparse-checkout set ts/src

  ## Examples

  See `examples/` for working scripts demonstrating both tools.
  """
end
