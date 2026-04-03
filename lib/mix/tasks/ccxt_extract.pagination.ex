defmodule Mix.Tasks.CcxtExtract.Pagination do
  @shortdoc "Extract pagination strategies from CCXT exchange TypeScript files"

  @moduledoc """
  Extracts pagination strategies from exchange TypeScript source files.

  Parses `priv/ccxt/ts/src/*.ts` via OXC, walks method bodies to find
  `this.fetchPaginatedCall*` call expressions, and writes per-exchange
  pagination data to `priv/discoveries/pagination.json`.

      mix ccxt_extract.pagination
  """

  use Mix.Task

  @impl true
  def run(args) do
    {_opts, leftover, invalid} = OptionParser.parse(args, strict: [])

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    Mix.shell().info("Extracting pagination strategies from exchange files...")

    {:ok, exchanges, stats} = CcxtExtract.Pagination.extract()
    CcxtExtract.Pagination.write!(exchanges)

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
