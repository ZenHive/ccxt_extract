defmodule Mix.Tasks.CcxtExtract.FetchMethods do
  @shortdoc "Extract fetch*() method ASTs from CCXT TypeScript source"

  @moduledoc """
  Extracts all `fetch*()` method bodies as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds all methods whose name starts
  with "fetch" on each exchange class, and writes the complete method ASTs
  (parameters, return type, and full body) to `priv/discoveries/fetch_methods.json`.

  Exchanges without any fetch methods are included with `"fetch_methods": {}`.

      mix ccxt_extract.fetch_methods
      mix ccxt_extract.fetch_methods --tier1 --dex
      mix ccxt_extract.fetch_methods --exchange binance,deribit

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate: only in-scope entries are replaced; out-of-scope entries
      are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Accepts repeated
      flags and comma-separated values. Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.Scope
  alias CcxtExtract.TaskScope

  @switches TaskScope.scope_switches()

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    universe = TaskScope.load_universe()
    scope = TaskScope.resolve_scope!(opts, universe)
    tier_scope = Scope.to_manifest_value(opts)

    Mix.shell().info("Extracting fetch*() method ASTs from REST exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.FetchMethods.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.FetchMethods.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_fetch = Enum.count(exchanges, fn e -> e["fetch_method_count"] > 0 end)
    total_methods = Enum.sum(Enum.map(exchanges, & &1["fetch_method_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_fetch} with fetch methods (#{total_methods} total).
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/fetch_methods.json
    """)
  end
end
