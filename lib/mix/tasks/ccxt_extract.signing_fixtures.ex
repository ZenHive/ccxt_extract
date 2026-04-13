defmodule Mix.Tasks.CcxtExtract.SigningFixtures do
  @shortdoc "Generate signing fixtures (frozen input/output) for all CCXT exchanges"

  @moduledoc """
  Generates signing test vectors by calling CCXT JS's `exchange.sign()` under
  frozen credentials, timestamps, and nonces.

  Writes one JSON file per non-alias exchange to `priv/fixtures/signing/<id>.json`,
  plus `_manifest.json`. Output is byte-identical across runs except `generated_at`.

  Consumers (ccxt_client Elixir, Rust/Go/Python ports) replay the frozen inputs
  and assert byte-equal sign() output.

      mix ccxt_extract.signing_fixtures

  Re-run after upgrading CCXT.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Generating signing fixtures from all CCXT exchanges...")

    {:ok, results} = CcxtExtract.SigningFixtures.extract()
    CcxtExtract.SigningFixtures.write!(results)

    Mix.shell().info("""
    Done. #{length(results)} fixtures written.
    Output: priv/fixtures/signing/
    """)
  end
end
