defmodule Mix.Tasks.CcxtExtract.WsMethods do
  @shortdoc "Extract watch*/handle* method ASTs from CCXT WS TypeScript source"

  @moduledoc """
  Extracts all `watch*()` and `handle*()` method bodies as raw ESTree AST for every WS exchange.

  Parses TypeScript source files in `pro/` via OXC, finds all methods whose name
  starts with "watch" or "handle" on each exchange class, and writes the complete
  method ASTs (parameters, return type, and full body) to `priv/discoveries/ws_methods.json`.

  Exchanges without any WS methods are included with `"ws_methods": {}`.

      mix ccxt_extract.ws_methods
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

    Mix.shell().info("Extracting watch*/handle* method ASTs from WS exchanges...")

    {:ok, exchanges, stats} = CcxtExtract.WsMethods.extract()
    CcxtExtract.WsMethods.write!(exchanges)

    with_ws = Enum.count(exchanges, fn e -> e["ws_method_count"] > 0 end)
    total_methods = Enum.sum(Enum.map(exchanges, & &1["ws_method_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_ws} with WS methods (#{total_methods} total).
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_methods.json
    """)
  end
end
