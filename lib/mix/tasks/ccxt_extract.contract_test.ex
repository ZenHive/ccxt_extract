defmodule Mix.Tasks.CcxtExtract.ContractTest do
  @shortdoc "Run cross-field semantic invariants over emitted per-exchange JSON"

  @moduledoc """
  Load emitted `priv/output/<exchange>.json` and run cross-field semantic
  invariants. Distinct from `mix ccxt_extract.validate` (JSON Schema +
  round-trip) — this catches drift that stays schema-valid but breaks
  consumer assumptions.

      mix ccxt_extract.contract_test
      mix ccxt_extract.contract_test --strict
      mix ccxt_extract.contract_test --report /tmp/contract.json

  ## Options

    * `--output DIR` — directory of emitted JSON (default: `priv/output`).
    * `--report PATH` — report file location (default:
      `<output_dir>/_contract_test_report.json`). Named `--report` rather
      than reusing `--output` because `--output` means "directory" in
      `mix ccxt_extract.validate` and `mix ccxt_extract.update`.
    * `--strict` — fail with non-zero exit if any findings.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, report: :string, strict: :boolean]
      )

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    output_dir = opts[:output] || CcxtExtract.Paths.priv("output")
    report_path = opts[:report] || Path.join(output_dir, "_contract_test_report.json")

    Mix.shell().info("Running contract tests on #{output_dir}...")
    start = System.monotonic_time(:millisecond)

    {:ok, report} = CcxtExtract.ContractTest.run_all(output_dir: output_dir)

    elapsed = System.monotonic_time(:millisecond) - start
    has_findings = report_results(report, elapsed)

    CcxtExtract.ContractTest.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")

    if opts[:strict] && has_findings do
      Mix.raise("Contract test found findings (strict mode). See report for details.")
    end
  end

  defp report_results(report, elapsed) do
    summary = report["summary"]
    total = summary["total_findings"]

    Mix.shell().info("""
    Done in #{elapsed}ms. #{summary["exchanges_checked"]} exchanges, \
    #{summary["invariants_run"]} invariants, #{total} findings.
    """)

    Enum.each(summary["findings_by_invariant"], fn {name, count} ->
      Mix.shell().info("  #{name}: #{count}")
    end)

    if total > 0, do: report_examples(report)

    total > 0
  end

  defp report_examples(report) do
    Mix.shell().error("Findings (first 20):")

    report["findings"]
    |> Enum.take(20)
    |> Enum.each(fn f ->
      Mix.shell().error("  [#{f["exchange"]}] #{f["invariant"]} @ #{f["path"]}: #{f["message"]}")
    end)
  end
end
