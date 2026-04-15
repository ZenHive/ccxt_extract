defmodule Mix.Tasks.CcxtExtract.PublicExchanges do
  @shortdoc "Classify exchanges by credential requirements from describe() data"

  @moduledoc """
  Reads per-exchange describe() JSON files and classifies each exchange by
  its credential requirements and whether it advertises `fetchMarkets`
  capability. Actual `loadMarkets()` callability is verified in Task 8b.

  Writes output to `priv/discoveries/public_exchanges.json`.

      mix ccxt_extract.public_exchanges
      mix ccxt_extract.public_exchanges --tier1 --dex
      mix ccxt_extract.public_exchanges --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict the analysis to the named
      priority tiers (combinable). Tier inheritance expands roots to their
      full family.
    * `--exchange ID` — restrict to explicit exchange IDs (repeatable or
      comma-separated). Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`. Out-of-scope
  per-exchange describe files are not read.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Analyzing exchange credential requirements...")

    case CcxtExtract.PublicExchanges.extract(scope) do
      {:ok, analysis} ->
        CcxtExtract.PublicExchanges.write!(analysis, tier_scope: tier_scope)

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
