defmodule Mix.Tasks.CcxtExtract.ParseMethods do
  @shortdoc "Extract parse*() method ASTs from CCXT TypeScript source"

  @moduledoc """
  Extracts all `parse*()` method bodies as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds all methods whose name starts
  with "parse" on each exchange class, and writes the complete method ASTs
  (parameters, return type, and full body) to `priv/discoveries/parse_methods.json`.

  Exchanges without any parse methods are included with `"parse_methods": {}`.

      mix ccxt_extract.parse_methods
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

    Mix.shell().info("Extracting parse*() method ASTs from REST exchanges...")

    {:ok, exchanges, stats} = CcxtExtract.ParseMethods.extract()
    CcxtExtract.ParseMethods.write!(exchanges)

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
