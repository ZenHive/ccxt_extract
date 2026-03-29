defmodule Mix.Tasks.CcxtExtract.Describe do
  @shortdoc "Extract complete describe() for all CCXT exchanges"

  @moduledoc """
  Extracts the full `describe()` output for every non-alias exchange via QuickBEAM.

  Writes one JSON file per exchange to `priv/discoveries/describe/` and a manifest
  at `priv/discoveries/describe/_manifest.json`.

      mix ccxt_extract.describe
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Extracting full describe() from all CCXT exchanges...")

    {:ok, results} = CcxtExtract.Describe.extract()
    CcxtExtract.Describe.write!(results)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/describe/ (one file per exchange + _manifest.json)
    """)
  end
end
