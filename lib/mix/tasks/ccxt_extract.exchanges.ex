defmodule Mix.Tasks.CcxtExtract.Exchanges do
  @shortdoc "Extract exchange metadata from CCXT"

  @moduledoc """
  Extracts exchange metadata from CCXT via QuickBEAM runtime.

  Loads the CCXT browser bundle, enumerates all exchange classes, and writes
  per-exchange metadata to `priv/discoveries/exchanges.json`.

      mix ccxt_extract.exchanges
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Extracting exchange metadata from CCXT...")

    {:ok, exchanges} = CcxtExtract.Exchanges.extract()

    aliases = Enum.count(exchanges, & &1["alias"])
    certified = Enum.count(exchanges, & &1["certified"])
    pro = Enum.count(exchanges, & &1["pro"])

    CcxtExtract.Exchanges.write!(exchanges)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges extracted.
      Certified: #{certified}
      Pro: #{pro}
      Aliases: #{aliases}
      Real (non-alias): #{length(exchanges) - aliases}
    Output: priv/discoveries/exchanges.json
    """)
  end
end
