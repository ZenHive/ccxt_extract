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
      mix ccxt_extract.contract_test --tier1 --tier2 --dex

  ## Options

    * `--output DIR` — directory of emitted JSON (default: `priv/output`).
    * `--report PATH` — report file location (default:
      `<output_dir>/_contract_test_report.json`). Named `--report` rather
      than reusing `--output` because `--output` means "directory" in
      `mix ccxt_extract.validate` and `mix ccxt_extract.update`.
    * `--strict` — fail with non-zero exit if any findings.
    * `--tier1 --tier2 --tier3 --dex` — restrict which exchanges are
      loaded and checked to members of the named priority tiers
      (combinable). Variants and aliases inherit their family root's
      tier, so `--tier1` pulls in `binance` and its variants
      (`binanceus`, `binancecoinm`, `binanceusdm`). Missing files for
      requested IDs are skipped with a warning.
  """

  use Mix.Task

  alias CcxtExtract.Tiers

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          report: :string,
          strict: :boolean,
          tier1: :boolean,
          tier2: :boolean,
          tier3: :boolean,
          dex: :boolean
        ]
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
    tier_filter = build_tier_filter(opts)

    Mix.shell().info(
      "Running contract tests on #{output_dir}" <>
        if(tier_filter, do: " [#{elem(tier_filter, 1)}]", else: "") <> "..."
    )

    start = System.monotonic_time(:millisecond)

    run_opts = build_run_opts(output_dir, tier_filter)
    warn_missing_scoped_files(output_dir, tier_filter)

    {:ok, report} = CcxtExtract.ContractTest.run_all(run_opts)

    elapsed = System.monotonic_time(:millisecond) - start
    has_findings = report_results(report, elapsed)

    CcxtExtract.ContractTest.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")

    if opts[:strict] && has_findings do
      Mix.raise("Contract test found findings (strict mode). See report for details.")
    end
  end

  defp build_tier_filter(opts) do
    if Tiers.has_tier_flags?(opts) do
      Tiers.collect_tier_exchanges(opts)
    end
  end

  defp build_run_opts(output_dir, nil), do: [output_dir: output_dir]

  defp build_run_opts(output_dir, {allowed, _label}) do
    [output_dir: output_dir, exchanges: allowed]
  end

  defp warn_missing_scoped_files(_output_dir, nil), do: :ok

  defp warn_missing_scoped_files(output_dir, {allowed, _label}) do
    present =
      output_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))
      |> Map.new(&{&1, true})

    missing = Enum.reject(allowed, &Map.has_key?(present, &1))

    if missing != [] do
      Mix.shell().info(
        "  Note: #{length(missing)} scoped exchange(s) missing from #{output_dir}: #{Enum.join(missing, ", ")}"
      )
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
