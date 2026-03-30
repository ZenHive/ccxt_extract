defmodule Mix.Tasks.CcxtExtract.HandleErrors do
  @shortdoc "Extract handleErrors() method AST from CCXT TypeScript source"

  @moduledoc """
  Extracts the `handleErrors()` method body as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds the `handleErrors()` method on each
  exchange class, and writes the complete method AST (parameters, return type,
  and full body) to `priv/discoveries/handle_errors.json`.

  Also includes `exceptions` and `httpExceptions` from each exchange's `describe()`
  output (extracted in Task 6) alongside the method AST.

  Exchanges without a `handleErrors()` method are included with `"handle_errors": null`.

      mix ccxt_extract.handle_errors
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

    Mix.shell().info("Extracting handleErrors() method AST from REST exchanges...")

    {:ok, exchanges, stats} = CcxtExtract.HandleErrors.extract()
    CcxtExtract.HandleErrors.write!(exchanges)

    with_handle_errors = Enum.count(exchanges, & &1["handle_errors"])
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_handle_errors} with handleErrors() method.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/handle_errors.json
    """)
  end
end
