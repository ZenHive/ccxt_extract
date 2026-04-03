defmodule Mix.Tasks.CcxtExtract.BaseMethods do
  @shortdoc "Extract base class method signatures from CCXT Exchange.ts"

  @moduledoc """
  Extracts `parse*()` and `safe*()` method signatures from the base Exchange class.

  Parses `priv/ccxt/ts/src/base/Exchange.ts` via OXC and writes all matching
  method signatures (name, category, params, return type, async) to
  `priv/discoveries/_base_methods.json`.

      mix ccxt_extract.base_methods
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

    Mix.shell().info("Extracting base class methods from Exchange.ts...")

    {:ok, result} = CcxtExtract.BaseMethods.extract()
    CcxtExtract.BaseMethods.write!(result)

    by_cat =
      Enum.map_join(result["by_category"], ", ", fn {cat, count} -> "#{count} #{cat}" end)

    Mix.shell().info("""
    Done. #{result["method_count"]} base methods extracted (#{by_cat}).
    Output: priv/discoveries/_base_methods.json
    """)
  end
end
