defmodule Mix.Tasks.CcxtExtract.UnifiedEndpoints do
  @shortdoc "Extract unified method → interface method mappings from CCXT exchange TypeScript files"

  @moduledoc """
  Extracts unified method to interface method mappings from exchange TypeScript source files.

  Parses `priv/ccxt/ts/src/*.ts` via OXC, walks unified method bodies to find
  `this.<interfaceMethod>()` call expressions, and writes per-exchange mappings
  to `priv/discoveries/unified_endpoints.json`.

      mix ccxt_extract.unified_endpoints
      mix ccxt_extract.unified_endpoints --tier1 --dex
      mix ccxt_extract.unified_endpoints --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate; out-of-scope entries are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Typos fail
      loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting unified endpoint mappings from exchange files...")

    {:ok, all_exchanges, stats} = CcxtExtract.UnifiedEndpoints.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.UnifiedEndpoints.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_endpoints = Enum.count(exchanges, fn e -> e["unified_endpoint_count"] > 0 end)
    total_mappings = Enum.sum(Enum.map(exchanges, & &1["unified_endpoint_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_endpoints} with unified endpoints, #{total_mappings} total mappings.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/unified_endpoints.json
    """)
  end
end
