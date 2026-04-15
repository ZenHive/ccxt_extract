defmodule Mix.Tasks.CcxtExtract.SigningFixtures do
  @shortdoc "Generate signing fixtures (frozen input/output) for all CCXT exchanges"

  @moduledoc """
  Generates signing test vectors by calling CCXT JS's `exchange.sign()` under
  frozen credentials, timestamps, and nonces.

  Writes one JSON file per non-alias exchange to `priv/fixtures/signing/<id>.json`,
  plus `_manifest.json`. Output is byte-identical across runs except `generated_at`.

  Consumers (ccxt_client Elixir, Rust/Go/Python ports) replay the frozen inputs
  and assert byte-equal sign() output.

  ## Usage

      mix ccxt_extract.signing_fixtures                     # full universe
      mix ccxt_extract.signing_fixtures --tier1 --dex       # tier1 + DEX
      mix ccxt_extract.signing_fixtures --exchange binance  # single exchange
      mix ccxt_extract.signing_fixtures --all               # explicit full run

  Scoped runs preserve out-of-scope fixtures from prior runs; only `--all`
  or no scope flag reasserts the full universe and prunes stale fixtures.

  Re-run after upgrading CCXT.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Generating signing fixtures from CCXT exchanges...")

    {:ok, results} = CcxtExtract.SigningFixtures.extract(scope: scope)
    CcxtExtract.SigningFixtures.write!(results, scope: scope, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(results)} fixtures written.
    Output: priv/fixtures/signing/
    """)
  end
end
