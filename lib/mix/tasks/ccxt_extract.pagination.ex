defmodule Mix.Tasks.CcxtExtract.Pagination do
  @shortdoc "Extract pagination strategies from CCXT exchange TypeScript files"

  @moduledoc """
  Extracts pagination strategies from exchange TypeScript source files.

  Parses `priv/ccxt/ts/src/*.ts` via OXC, walks method bodies to find
  `this.fetchPaginatedCall*` call expressions, and writes per-exchange
  pagination data to `priv/discoveries/pagination.json`.

      mix ccxt_extract.pagination
      mix ccxt_extract.pagination --tier1 --dex
      mix ccxt_extract.pagination --exchange binance

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

    Mix.shell().info("Extracting pagination strategies from exchange files...")

    {:ok, all_exchanges, stats} = CcxtExtract.Pagination.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.Pagination.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_pagination = Enum.count(exchanges, fn e -> e["pagination_count"] > 0 end)
    total_entries = Enum.sum(Enum.map(exchanges, & &1["pagination_count"]))
    error_count = length(stats.errors)

    total_unresolved =
      exchanges
      |> Enum.map(fn e -> length(Map.get(e, "pagination_unresolved", [])) end)
      |> Enum.sum()

    unresolved_msg = if total_unresolved > 0, do: ", #{total_unresolved} unresolved", else: ""

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_pagination} with pagination, #{total_entries} total entries#{unresolved_msg}.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/pagination.json
    """)
  end
end
