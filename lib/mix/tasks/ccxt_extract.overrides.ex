defmodule Mix.Tasks.CcxtExtract.Overrides do
  @shortdoc "Extract method override data for derived CCXT exchanges"

  @moduledoc """
  Extracts method override data for every exchange that extends another exchange.

  Runs `Classes.extract/0` to get the class hierarchy, computes which methods
  are overridden vs. new vs. inherited for each derived class, then re-parses
  TypeScript source to extract full AST bodies for overridden and new methods.

  Exchanges that extend `Exchange` directly are excluded — all their methods
  are "new" by definition, which is not useful override data.

      mix ccxt_extract.overrides
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

    Mix.shell().info("Extracting method overrides for derived exchanges...")

    {:ok, exchanges, stats} = CcxtExtract.Overrides.extract()
    summary = CcxtExtract.Overrides.write!(exchanges)

    class_error_count = length(stats.class_errors)
    override_error_count = length(stats.errors)

    if class_error_count > 0 do
      Mix.shell().error(
        "WARNING: #{class_error_count} class parse error(s) — hierarchy may be incomplete, some overrides could be misclassified as new methods."
      )
    end

    Mix.shell().info("""
    Done. #{length(exchanges)} derived exchanges analyzed, \
    #{summary.with_overrides} with overrides (#{summary.total_overrides} total), \
    #{summary.total_new} new methods.
    #{if override_error_count > 0, do: "#{override_error_count} override parse error(s).", else: ""}
    Output: priv/discoveries/overrides.json
    """)
  end
end
