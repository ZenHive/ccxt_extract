defmodule Mix.Tasks.CcxtExtract.SignMethods do
  @shortdoc "Extract sign() method AST from CCXT TypeScript source"

  @moduledoc """
  Extracts the `sign()` method body as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds the `sign()` method on each
  exchange class, and writes the complete method AST (parameters, return type,
  and full body) to `priv/discoveries/sign_methods.json`.

  Exchanges without a `sign()` method are included with `"sign": null`.

      mix ccxt_extract.sign_methods
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

    Mix.shell().info("Extracting sign() method AST from REST exchanges...")

    {:ok, exchanges, stats} = CcxtExtract.SignMethod.extract()
    CcxtExtract.SignMethod.write!(exchanges)

    with_sign = Enum.count(exchanges, & &1["sign"])
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_sign} with sign() method.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/sign_methods.json
    """)
  end
end
