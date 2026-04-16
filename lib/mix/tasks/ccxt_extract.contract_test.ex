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
      mix ccxt_extract.contract_test --exchange binance,deribit

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
      requested IDs are skipped with a non-fatal note.
    * `--exchange ID` — restrict to explicit exchange IDs. Repeatable
      and comma-split (`--exchange binance,deribit`). Combines with
      tier flags. Unknown IDs abort with fuzzy suggestions.
    * `--all` — entire universe; conflicts with any narrowing flag.

  ## Universe mismatch

  With no scope flag (or `--all`) the task expects every exchange in the
  CCXT TypeScript universe to be present in `--output`. If any are
  missing, the task aborts with a remediation message — the likely cause
  is a prior scoped extract that left `priv/output/` as a partial view.
  Run `mix ccxt_extract.update` or re-run with matching scope flags.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @switches Keyword.merge(
              [output: :string, report: :string, strict: :boolean],
              TaskScope.scope_switches()
            )

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    output_dir = opts[:output] || CcxtExtract.Paths.out("output")
    report_path = opts[:report] || Path.join(output_dir, "_contract_test_report.json")

    universe = TaskScope.load_universe()
    scope = TaskScope.resolve_scope!(opts, universe)

    check_corpus!(scope, universe, output_dir)

    Mix.shell().info("Running contract tests on #{output_dir}...")

    start = System.monotonic_time(:millisecond)
    {:ok, report} = CcxtExtract.ContractTest.run_all(run_opts(output_dir, scope))

    elapsed = System.monotonic_time(:millisecond) - start
    has_findings = report_results(report, elapsed)

    CcxtExtract.ContractTest.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")

    if opts[:strict] && has_findings do
      Mix.raise("Contract test found findings (strict mode). See report for details.")
    end
  end

  defp run_opts(output_dir, :all), do: [output_dir: output_dir]

  defp run_opts(output_dir, %MapSet{} = scope), do: [output_dir: output_dir, exchanges: Enum.sort(scope)]

  defp check_corpus!(:all, universe, output_dir) do
    missing = TaskScope.scoped_ids_missing_file(MapSet.new(universe), output_dir)
    if missing != [], do: Mix.raise(universe_mismatch_message(output_dir, missing))
    :ok
  end

  defp check_corpus!(%MapSet{} = scope, _universe, output_dir) do
    missing = TaskScope.scoped_ids_missing_file(scope, output_dir)

    if missing != [] do
      Mix.shell().info(
        "  Note: #{length(missing)} scoped exchange(s) missing from #{output_dir}: #{Enum.join(missing, ", ")}"
      )
    end

    :ok
  end

  defp universe_mismatch_message(output_dir, missing) do
    count = length(missing)
    preview = missing |> Enum.take(10) |> Enum.join(", ")
    suffix = if count > 10, do: ", … (#{count - 10} more)", else: ""

    """
    Universe mismatch: #{count} exchange(s) from the CCXT TypeScript \
    source are missing in #{output_dir}.

      #{preview}#{suffix}

    A full-universe run (no scope flag, or `--all`) expects every \
    exchange to be present. The likely cause is a prior scoped \
    extract leaving `priv/output/` as a partial view.

    Fix by regenerating the full corpus:

        mix ccxt_extract.update

    Or narrow the contract test to match what's on disk:

        mix ccxt_extract.contract_test --tier1 --tier2 --dex
        mix ccxt_extract.contract_test --exchange <id>[,<id>...]
    """
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
