defmodule Mix.Tasks.CcxtExtract.ValidateOverrides do
  @shortdoc "Cross-check override entries against runtime/AST probes"

  @moduledoc """
  Audits every `priv/overrides/<id>.json` entry and writes a per-exchange report
  (`verified` / `unverified` / `warning` / `mismatch` / `error`).

      mix ccxt_extract.validate_overrides
      mix ccxt_extract.validate_overrides --strict
      mix ccxt_extract.validate_overrides --report /tmp/override_validation.json
      mix ccxt_extract.validate_overrides --exchange hyperliquid,gate
      mix ccxt_extract.validate_overrides --overrides /path/to/overrides

  ## Options

    * `--discoveries DIR` — discovery corpus (default: `priv/discoveries`).
    * `--overrides DIR` — override files dir (default: `priv/overrides`).
    * `--report PATH` — report output (default:
      `priv/discoveries/override_validation_report.json` via `Paths.out/1`).
    * `--strict` — exit non-zero on mismatch, error, warning, or entries with
      `unverified: true`. Informational `unverified` (e.g. `no_probe_for_path`)
      does not fail strict mode.
    * `--exchange ID` — comma-separated and repeatable exchange filter. When
      omitted, every `.json` file in the `--overrides` dir is checked.
  """

  use Mix.Task

  @switches [
    discoveries: :string,
    overrides: :string,
    report: :string,
    strict: :boolean,
    exchange: :keep
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

    discoveries_dir = opts[:discoveries] || CcxtExtract.Paths.priv("discoveries")
    overrides_dir = opts[:overrides] || CcxtExtract.Paths.priv("overrides")
    report_path = opts[:report] || CcxtExtract.ValidateOverrides.default_report_path()

    run_opts = maybe_put_exchange_ids([discoveries_dir: discoveries_dir, overrides_dir: overrides_dir], opts)

    Mix.shell().info("Validating overrides against #{discoveries_dir}...")
    start = System.monotonic_time(:millisecond)

    {:ok, report} = CcxtExtract.ValidateOverrides.run(run_opts)

    elapsed = System.monotonic_time(:millisecond) - start
    report_results(report, elapsed)

    CcxtExtract.ValidateOverrides.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")

    if opts[:strict] && CcxtExtract.ValidateOverrides.strict_failure?(report) do
      Mix.raise("Override validation found strict-class findings. See report for details.")
    end
  end

  # Returns nil when `--exchange` is absent so `ValidateOverrides.run/1` falls
  # back to its own default — every `.json` file in the resolved overrides dir.
  # Computing the default here would ignore `--overrides`.
  defp maybe_put_exchange_ids(run_opts, opts) do
    case parse_exchange_ids(opts) do
      nil -> run_opts
      ids -> Keyword.put(run_opts, :exchange_ids, ids)
    end
  end

  defp parse_exchange_ids(opts) do
    # `--exchange` is `:keep`, so OptionParser yields one `{:exchange, val}` per
    # occurrence — use `Keyword.get_values/2`, not `opts[:exchange]` (which would
    # return only the first). Each value may itself be comma-separated.
    case Keyword.get_values(opts, :exchange) do
      [] ->
        nil

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
    Done in #{elapsed}ms. #{s["exchanges"]} exchanges, #{s["entries"]} entries: \
    #{s["verified"]} verified, #{s["unverified"]} unverified, \
    #{s["warnings"]} warnings, #{s["mismatches"]} mismatches, #{s["errors"]} errors.
    """)

    report["exchanges"]
    |> Enum.flat_map(fn %{"exchange" => id, "entries" => entries} ->
      Enum.map(entries, fn entry -> {id, entry} end)
    end)
    |> Enum.reject(fn {_id, entry} -> entry["status"] == "verified" end)
    |> Enum.take(20)
    |> Enum.each(fn {id, entry} ->
      Mix.shell().error("  [#{id}] #{entry["path"]} -> #{entry["status"]}: #{entry["reason"] || entry["probe"]}")
    end)
  end
end
