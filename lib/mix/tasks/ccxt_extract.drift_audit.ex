defmodule Mix.Tasks.CcxtExtract.DriftAudit do
  @shortdoc "Compare current derivation + overrides against last-released output (report only)"

  @moduledoc """
  Report-only audit of drift between the current assembled output (current derivation
  + overrides applied) and a baseline "last-released" output snapshot.

  Loads the baseline from a git release tag/ref (`git show TAG:priv/output/<id>.json`)
  or from an explicit directory of baseline JSONs. Never mutates overrides or output.

  Flags three categories:
  - stale overrides (override-applied value or mapped raw source changed vs baseline)
  - derived fields whose value flipped or disappeared
  - new raw fields that have no derivation yet

  Each finding names the exchange, RFC 6901 JSON pointer, and before/after values.

      mix ccxt_extract.drift_audit --baseline-tag v0.2.0
      mix ccxt_extract.drift_audit --baseline-tag 0fbbadc187adcb5826a979142d725cfdbcc3bbec --exchange binance
      mix ccxt_extract.drift_audit --baseline-dir /path/to/prev-release/output
      mix ccxt_extract.drift_audit --baseline-tag vX.Y.Z --report /tmp/drift.json

  Exits non-zero only on hard errors (bad args, unreadable current manifest, etc.).
  Presence of findings never produces a non-zero exit (CI can consume the report
  and decide separately).

  ## Options

    * `--baseline-tag REF` — git ref (tag or commit SHA) whose tree supplies the
      baseline `priv/output/<id>.json` files.
    * `--baseline-dir DIR` — directory containing baseline `<id>.json` files
      (e.g. an unpacked prior release or a consumer's vendored corpus). Takes
      precedence when both `--baseline-*` flags are present.
    * `--output DIR` — current output directory (default: `priv/output` via Paths).
    * `--exchange ID` — comma-separated and repeatable filter. Defaults to every
      exchange listed in the current manifest.
    * `--report PATH` — write the full JSON report (default:
      `priv/discoveries/drift_audit_report.json` via Paths.out/1).
  """

  use Mix.Task

  @switches [
    baseline_tag: :string,
    baseline_dir: :string,
    output: :string,
    exchange: :keep,
    report: :string
  ]

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

    if is_nil(opts[:baseline_tag]) and is_nil(opts[:baseline_dir]) do
      Mix.raise("Required: --baseline-tag REF or --baseline-dir DIR (see --help)")
    end

    output_dir = opts[:output] || CcxtExtract.Paths.out("output")
    report_path = opts[:report] || default_report_path()

    run_opts =
      maybe_put_exchange_ids(
        [output_dir: output_dir, baseline_tag: opts[:baseline_tag], baseline_dir: opts[:baseline_dir]],
        opts
      )

    Mix.shell().info("Drift audit against #{describe_baseline(opts)} (current: #{output_dir})...")
    start = System.monotonic_time(:millisecond)

    {:ok, report} = CcxtExtract.DriftAudit.run(run_opts)

    elapsed = System.monotonic_time(:millisecond) - start
    report_results(report, elapsed)

    CcxtExtract.DriftAudit.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")
  end

  defp default_report_path, do: CcxtExtract.Paths.out("discoveries/drift_audit_report.json")

  defp describe_baseline(opts) do
    cond do
      opts[:baseline_dir] -> "dir:#{opts[:baseline_dir]}"
      opts[:baseline_tag] -> "tag:#{opts[:baseline_tag]}"
      true -> "none"
    end
  end

  defp maybe_put_exchange_ids(run_opts, opts) do
    case parse_exchange_ids(opts) do
      [] -> run_opts
      ids -> Keyword.put(run_opts, :exchange_ids, ids)
    end
  end

  defp parse_exchange_ids(opts) do
    case Keyword.get_values(opts, :exchange) do
      [] ->
        []

      values ->
        values
        |> Enum.flat_map(&String.split(&1, ",", trim: true))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
    end
  end

  defp report_results(report, elapsed) do
    s = report["summary"]

    Mix.shell().info("""
    Done in #{elapsed}ms. #{s["exchanges_compared"]} exchanges.
    stale_overrides: #{s["stale_overrides"]}, \
    flipped_derived: #{s["flipped_derived"]}, \
    new_raw: #{s["new_raw"]}, \
    total_findings: #{s["total_findings"]}.
    """)

    # Print a bounded sample per category so a human sees the shape without
    # flooding the terminal on a full-universe run.
    report["findings"]
    |> Enum.group_by(& &1["category"])
    |> Enum.each(fn {cat, list} ->
      Mix.shell().info("  [#{cat}] #{length(list)} finding(s)")

      list
      |> Enum.take(3)
      |> Enum.each(fn f ->
        bef = format_value(f["before"])
        aft = format_value(f["after"])
        Mix.shell().info("    #{f["exchange"]} #{f["path"]}")
        Mix.shell().info("      before: #{bef}")
        Mix.shell().info("      after:  #{aft}")
      end)
    end)
  end

  defp format_value(nil), do: "null"
  defp format_value(v) when is_binary(v), do: inspect(v)
  defp format_value(v) when is_number(v) or is_boolean(v), do: inspect(v)

  defp format_value(v) when is_map(v) or is_list(v) do
    bin = Jason.encode!(v)
    if byte_size(bin) > 120, do: String.slice(bin, 0, 117) <> "...", else: bin
  rescue
    _ -> inspect(v, limit: 5)
  end

  defp format_value(v), do: inspect(v, limit: 5)
end
