defmodule Mix.Tasks.CcxtExtract.PublicExchanges do
  @shortdoc "Classify exchanges by credential requirements from describe() data"

  @moduledoc """
  Reads per-exchange describe() JSON files and classifies each exchange by
  its credential requirements and whether it advertises `fetchMarkets`
  capability. Actual `loadMarkets()` callability is verified in Task 8b.

  Writes output to `priv/discoveries/public_exchanges.json`.

      mix ccxt_extract.public_exchanges
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Analyzing exchange credential requirements...")

    case CcxtExtract.PublicExchanges.extract() do
      {:ok, analysis} ->
        CcxtExtract.PublicExchanges.write!(analysis)

        summary = analysis["summary"]

        Mix.shell().info(
          "Done. #{analysis["exchange_count"]} exchanges classified.\n" <>
            "fetchMarkets advertised: #{summary["fetch_markets_advertised_count"]}\n" <>
            "Fully public (no credentials): #{summary["fully_public_count"]}\n" <>
            "Credential patterns: #{summary["credential_pattern_count"]}\n" <>
            "Output: priv/discoveries/public_exchanges.json"
        )

      {:error, {:missing_input, path}} ->
        Mix.raise("Missing input: #{path}\nRun `mix ccxt_extract.describe` first to generate describe() data.")
    end
  end
end
