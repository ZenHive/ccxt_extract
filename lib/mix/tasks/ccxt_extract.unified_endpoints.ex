defmodule Mix.Tasks.CcxtExtract.UnifiedEndpoints do
  @shortdoc "Extract unified method → interface method mappings from CCXT exchange TypeScript files"

  @moduledoc """
  Extracts unified method to interface method mappings from exchange TypeScript source files.

  Parses `priv/ccxt/ts/src/*.ts` via OXC, walks unified method bodies to find
  `this.<interfaceMethod>()` call expressions, and writes per-exchange mappings
  to `priv/discoveries/unified_endpoints.json`.

      mix ccxt_extract.unified_endpoints
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

    Mix.shell().info("Extracting unified endpoint mappings from exchange files...")

    {:ok, exchanges, stats} = CcxtExtract.UnifiedEndpoints.extract()
    CcxtExtract.UnifiedEndpoints.write!(exchanges)

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
