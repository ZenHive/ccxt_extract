defmodule Mix.Tasks.CcxtExtract.InterfaceSignatures do
  @shortdoc "Extract interface method signatures from CCXT abstract TypeScript files"

  @moduledoc """
  Extracts typed API method signatures from abstract interface declarations.

  Parses `priv/ccxt/ts/src/abstract/*.ts` via OXC, finds the `Exchange`
  interface in each file, and writes all method signatures (name, params,
  return type) to `priv/discoveries/interface_signatures.json`.

      mix ccxt_extract.interface_signatures
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

    Mix.shell().info("Extracting interface signatures from abstract exchange files...")

    {:ok, exchanges, stats} = CcxtExtract.InterfaceSignatures.extract()
    CcxtExtract.InterfaceSignatures.write!(exchanges)

    with_sigs = Enum.count(exchanges, fn e -> e["interface_signature_count"] > 0 end)
    total_sigs = Enum.sum(Enum.map(exchanges, & &1["interface_signature_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_sigs} with signatures, #{total_sigs} total signatures.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/interface_signatures.json
    """)
  end
end
