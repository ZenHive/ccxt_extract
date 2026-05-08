defmodule Mix.Tasks.CcxtExtract.Validate do
  @shortdoc "Validate per-exchange JSON against schema and source data"

  @moduledoc """
  Full validation of pipeline output: JSON Schema conformance (draft 2020-12)
  and round-trip comparison against source discovery data.

      mix ccxt_extract.validate
      mix ccxt_extract.validate --strict
      mix ccxt_extract.validate --schema-only
      mix ccxt_extract.validate --output /tmp/exchanges

  ## Options

    * `--output DIR` — directory of emitted JSON files to validate (default: `priv/output`).
      Reads per-exchange `*.json` and `_manifest.json` from this directory.
      The validation report (`_validation_report.json`) is also written here.
    * `--strict` — fail with non-zero exit if any errors found
    * `--schema-only` — skip round-trip comparison (faster)
    * `--schema-target N` — `3` (default) validates against
      `priv/schema/exchange_v3.json`; `4` validates against
      `priv/schema/exchange_v4.json` (gated, Task 130).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          strict: :boolean,
          schema_only: :boolean,
          schema_target: :integer
        ]
      )

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    output_dir = opts[:output] || CcxtExtract.Paths.out("output")
    schema_target = resolve_schema_target!(opts)

    Mix.shell().info("Validating output in #{output_dir}#{target_suffix(schema_target)}...")
    start = System.monotonic_time(:millisecond)

    validation_opts = [
      output_dir: output_dir,
      schema_only: opts[:schema_only] || false,
      tier_scope: read_manifest_tier_scope(output_dir),
      schema_target: schema_target
    ]

    {:ok, report} = CcxtExtract.Validation.validate_all(validation_opts)

    elapsed = System.monotonic_time(:millisecond) - start
    has_errors = report_results(report, elapsed)

    report_path = Path.join(output_dir, "_validation_report.json")
    CcxtExtract.Validation.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")

    if opts[:strict] && has_errors do
      Mix.raise("Validation found errors (strict mode). See report for details.")
    end
  end

  @spec resolve_schema_target!(keyword()) :: 3 | 4
  defp resolve_schema_target!(opts) do
    case Keyword.get(opts, :schema_target, 3) do
      3 -> 3
      4 -> 4
      other -> Mix.raise("Invalid --schema-target #{inspect(other)}; expected 3 or 4")
    end
  end

  @spec target_suffix(3 | 4) :: String.t()
  defp target_suffix(3), do: ""
  defp target_suffix(4), do: " (schema target: v4 — gated)"

  # Returns true if there are errors
  defp report_results(report, elapsed) do
    summary = report["summary"]

    Mix.shell().info("""
    Done in #{elapsed}ms. #{report["exchange_count"]} exchanges validated.
    Schema: #{summary["schema_pass"]} passed, #{summary["schema_fail"]} failed.
    Round-trip: #{summary["roundtrip_checked"]} checked, #{summary["roundtrip_clean"]} clean, #{summary["roundtrip_with_findings"]} with findings.
    Findings: #{summary["total_errors"]} errors, #{summary["total_warnings"]} warnings, #{summary["total_info"]} info.
    """)

    has_gaps = report_integrity_gaps(report["pipeline_stats"])
    report_top_errors(report, summary)

    summary["total_errors"] > 0 || has_gaps
  end

  defp report_integrity_gaps(ps) do
    manifest_error = ps["manifest_error"]

    gap_types = [
      {"missing", ps["missing_entries"]},
      {"corrupt", ps["corrupt_entries"]},
      {"orphan", ps["orphan_entries"]},
      {"id_mismatch", ps["id_mismatch_entries"]}
    ]

    has_gaps = manifest_error != nil || Enum.any?(gap_types, fn {_, entries} -> entries != [] end)

    if manifest_error do
      Mix.shell().error("Manifest error: #{manifest_error}")
    end

    if Enum.any?(gap_types, fn {_, entries} -> entries != [] end) do
      Mix.shell().error("Pipeline data gaps:")

      Enum.each(gap_types, fn {label, entries} ->
        Enum.each(entries, &Mix.shell().error("  [#{label}] #{&1}"))
      end)
    end

    has_gaps
  end

  # The validate mix task doesn't parse scope flags — it checks whatever
  # the pipeline wrote. Derive the active scope from the emitted manifest
  # so the validation report reflects reality. Falls back to "all" when
  # the manifest is missing or doesn't carry a stamp.
  defp read_manifest_tier_scope(output_dir) do
    path = Path.join(output_dir, "_manifest.json")

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, %{"tier_scope" => ts}} when not is_nil(ts) -> ts
      _ -> "all"
    end
  end

  defp report_top_errors(report, summary) do
    if summary["total_errors"] > 0 do
      Mix.shell().error("Errors:")

      report["findings_by_severity"]["error"]
      |> Enum.take(20)
      |> Enum.each(fn f ->
        Mix.shell().error("  [#{f["exchange_id"]}] #{f["path"]}: #{f["message"]}")
      end)
    end
  end
end
