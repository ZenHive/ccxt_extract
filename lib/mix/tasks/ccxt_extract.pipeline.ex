defmodule Mix.Tasks.CcxtExtract.Pipeline do
  @shortdoc "Assemble per-exchange JSON files from all extraction outputs"

  @moduledoc """
  Reads all discovery data and assembles validated per-exchange JSON files
  conforming to the `exchange_v1.json` schema.

  Each output file combines runtime data (describe, markets) and structural
  data (class hierarchy, method ASTs, overrides) into a single JSON document.
  The output directory also includes `_manifest.json` and `exchange_v1.json`.

      mix ccxt_extract.pipeline
      mix ccxt_extract.pipeline --output /tmp/exchange_output
      mix ccxt_extract.pipeline --strict

  ## Options

    * `--output` — custom output directory (default: `priv/output`); stale exchange JSON files are cleaned automatically
    * `--strict` — fail with non-zero exit if validation errors or missing per-exchange files
  """

  use Mix.Task

  @progress_interval 20

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args, strict: [output: :string, strict: :boolean])

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
        has_issues = report_results(exchanges, stats, output_dir, elapsed)

        if opts[:strict] && has_issues do
          Mix.raise("Pipeline completed with issues (strict mode). See above for details.")
        end

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

  # Returns true if there are issues (for --strict mode)
  defp report_results(exchanges, stats, output_dir, elapsed) do
    validation_line =
      if stats.validation_errors == [],
        do: "All exchanges passed validation.",
        else: "#{length(stats.validation_errors)} validation error(s)."

    detail_lines =
      [
        stat_line("Missing discovery files", stats.missing_files, &Enum.join(&1, ", ")),
        stat_line("Missing per-exchange files", stats.missing_entries, &format_missing_entries/1),
        stat_line("Corrupt discovery entries", stats.corrupt_entries, &format_missing_entries/1),
        stat_line("Orphan artifacts", stats.orphan_entries, &format_missing_entries/1),
        stat_line("ID mismatches", stats.id_mismatch_entries, &format_missing_entries/1)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Mix.shell().info("""
    Done in #{elapsed}ms. #{length(exchanges)} exchanges assembled.
    #{validation_line}
    #{detail_lines}
    Output: #{output_dir}/
    """)

    has_data_issues?(stats)
  end

  defp stat_line(_label, [], _formatter), do: nil
  defp stat_line(label, entries, formatter), do: "#{label} (#{length(entries)}): #{formatter.(entries)}"

  defp has_data_issues?(stats) do
    stats.validation_errors != [] or stats.missing_entries != [] or
      stats.corrupt_entries != [] or stats.orphan_entries != [] or
      stats.id_mismatch_entries != []
  end

  @max_displayed_entries 10

  defp format_missing_entries(entries) do
    displayed = Enum.take(entries, @max_displayed_entries)
    suffix = if length(entries) > @max_displayed_entries, do: ", ...", else: ""
    Enum.join(displayed, ", ") <> suffix
  end
end
