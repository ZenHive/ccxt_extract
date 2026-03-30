defmodule Mix.Tasks.CcxtExtract.Coverage do
  @shortdoc "Generate extraction coverage report"

  @moduledoc """
  Analyzes all extraction outputs and reports per-exchange coverage.

  Reads existing JSON files from all extraction phases and reports what
  data exists for each exchange, identifies gaps with explanations,
  and computes summary statistics.

      mix ccxt_extract.coverage
  """

  use Mix.Task

  @impl true
  def run(args) do
    if args != [] do
      Mix.raise("This task takes no arguments. Usage: mix ccxt_extract.coverage")
    end

    Mix.shell().info("Generating coverage report...")
    start_time = System.monotonic_time(:millisecond)

    case CcxtExtract.CoverageReport.extract() do
      {:ok, report} ->
        elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000
        CcxtExtract.CoverageReport.write!(report)
        print_summary(report, elapsed_s)

      {:error, {:missing_input, path}} ->
        Mix.raise("""
        Missing required input: #{path}

        Run extraction tasks first:
          mix ccxt_extract.exchanges
        """)
    end
  end

  defp print_summary(report, elapsed_s) do
    summary = report["summary"]

    Mix.shell().info("""
    Done in #{Float.round(elapsed_s, 1)}s.
      Exchanges: #{report["exchange_count"]}
      Full coverage: #{summary["full_coverage"]}
      Partial coverage: #{summary["partial_coverage"]}
      No coverage: #{summary["no_coverage"]}
      Avg coverage: #{summary["avg_coverage_pct"]}%
      Output: priv/discoveries/coverage_report.json
    """)

    if summary["missing_files"] != [] do
      Mix.shell().info("  Missing input files:")

      for file <- summary["missing_files"] do
        Mix.shell().info("    - #{file}")
      end
    end

    per_layer = summary["per_layer"]
    Mix.shell().info("  Per-layer coverage:")

    for name <- CcxtExtract.CoverageReport.layer_names() do
      layer = per_layer[name]
      Mix.shell().info("    #{String.pad_trailing(name, 18)} #{layer["present"]}/#{layer["applicable"]}")
    end

    gaps = report["gaps_summary"]

    if gaps != [] do
      top_gaps = Enum.take(gaps, 10)
      Mix.shell().info("\n  Top gaps (#{length(gaps)} exchanges with gaps):")

      for gap <- top_gaps do
        Mix.shell().info("    #{gap["id"]}: #{Enum.join(gap["gaps"], ", ")}")
      end
    end
  end
end
