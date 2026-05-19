defmodule Mix.Tasks.CcxtExtract.ParseMethods do
  @shortdoc "Extract parse*() method ASTs from CCXT TypeScript source"

  @moduledoc """
  Extracts all `parse*()` method bodies as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds all methods whose name starts
  with "parse" on each exchange class, and writes the complete method ASTs
  (parameters, return type, and full body) to `priv/discoveries/parse_methods.json`.

  Exchanges without any parse methods are included with `"parse_methods": {}`.

      mix ccxt_extract.parse_methods
      mix ccxt_extract.parse_methods --tier1 --dex
      mix ccxt_extract.parse_methods --exchange binance,deribit

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

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting parse*() method ASTs from REST exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.ParseMethods.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.ParseMethods.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_parse = Enum.count(exchanges, fn e -> e["parse_method_count"] > 0 end)
    total_methods = Enum.sum(Enum.map(exchanges, & &1["parse_method_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_parse} with parse methods (#{total_methods} total).
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/parse_methods.json
    """)
  end
end
