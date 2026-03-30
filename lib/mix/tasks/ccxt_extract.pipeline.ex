defmodule Mix.Tasks.CcxtExtract.Pipeline do
  @shortdoc "Assemble per-exchange JSON files from all extraction outputs"

  @moduledoc """
  Reads all discovery data and assembles validated per-exchange JSON files
  conforming to the `exchange_v1.json` schema.

  Each output file combines runtime data (describe, markets) and structural
  data (class hierarchy, method ASTs, overrides) into a single JSON document.

      mix ccxt_extract.pipeline
      mix ccxt_extract.pipeline --output /tmp/exchange_output

  ## Options

    * `--output` — custom output directory (default: `priv/output`)
  """

  use Mix.Task

  @progress_interval 20

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args, strict: [output: :string])

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    Mix.shell().info("Assembling per-exchange JSON from discovery data...")
    start = System.monotonic_time(:millisecond)

    case CcxtExtract.Pipeline.extract() do
      {:ok, exchanges, stats} ->
        report_progress(exchanges)
        output_dir = opts[:output] || CcxtExtract.Paths.priv("output")
        CcxtExtract.Pipeline.write!(exchanges, output_dir)

        elapsed = System.monotonic_time(:millisecond) - start
        report_results(exchanges, stats, output_dir, elapsed)

      {:error, {:missing_input, path}} ->
        Mix.raise("Missing required input: #{path}")
    end
  end

  defp report_progress(exchanges) do
    total = length(exchanges)

    if total > @progress_interval do
      Mix.shell().info("  Assembled #{total} exchanges.")
    end
  end

  defp report_results(exchanges, stats, output_dir, elapsed) do
    error_count = length(stats.validation_errors)
    missing_count = length(stats.missing_files)

    Mix.shell().info("""
    Done in #{elapsed}ms. #{length(exchanges)} exchanges assembled.
    #{if error_count > 0, do: "#{error_count} validation error(s).", else: "All exchanges passed validation."}
    #{if missing_count > 0, do: "Missing discovery files: #{Enum.join(stats.missing_files, ", ")}", else: ""}
    Output: #{output_dir}/
    """)
  end
end
