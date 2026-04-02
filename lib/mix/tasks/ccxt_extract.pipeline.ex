defmodule Mix.Tasks.CcxtExtract.Pipeline do
  @shortdoc "Assemble per-exchange JSON files from all extraction outputs"

  @moduledoc """
  Reads all discovery data and assembles validated per-exchange JSON files
  conforming to the `exchange_v1.json` schema.

  Each output file combines runtime data (describe, markets) and structural
  data (class hierarchy, method ASTs, overrides) into a single JSON document.

      mix ccxt_extract.pipeline
      mix ccxt_extract.pipeline --output /tmp/exchange_output
      mix ccxt_extract.pipeline --strict

  ## Options

    * `--output` — custom output directory (default: `priv/output`)
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
    error_count = length(stats.validation_errors)
    missing_count = length(stats.missing_files)
    missing_entry_count = length(stats.missing_entries)
    corrupt_count = length(stats.corrupt_entries)
    orphan_count = length(stats.orphan_entries)
    id_mismatch_count = length(stats.id_mismatch_entries)

    Mix.shell().info("""
    Done in #{elapsed}ms. #{length(exchanges)} exchanges assembled.
    #{if error_count > 0, do: "#{error_count} validation error(s).", else: "All exchanges passed validation."}
    #{if missing_count > 0, do: "Missing discovery files: #{Enum.join(stats.missing_files, ", ")}", else: ""}
    #{if missing_entry_count > 0, do: "Missing per-exchange files (#{missing_entry_count}): #{format_missing_entries(stats.missing_entries)}", else: ""}
    #{if corrupt_count > 0, do: "Corrupt discovery entries (#{corrupt_count}): #{format_missing_entries(stats.corrupt_entries)}", else: ""}
    #{if orphan_count > 0, do: "Orphan artifacts (#{orphan_count}): #{format_missing_entries(stats.orphan_entries)}", else: ""}
    #{if id_mismatch_count > 0, do: "ID mismatches (#{id_mismatch_count}): #{format_missing_entries(stats.id_mismatch_entries)}", else: ""}
    Output: #{output_dir}/
    """)

    error_count > 0 or missing_entry_count > 0 or corrupt_count > 0 or orphan_count > 0 or
      id_mismatch_count > 0
  end

  @max_displayed_entries 10

  defp format_missing_entries(entries) do
    displayed = Enum.take(entries, @max_displayed_entries)
    suffix = if length(entries) > @max_displayed_entries, do: ", ...", else: ""
    Enum.join(displayed, ", ") <> suffix
  end
end
