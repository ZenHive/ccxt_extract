defmodule Mix.Tasks.CcxtExtract.Validate do
  @shortdoc "Validate per-exchange JSON against schema and source data"

  @moduledoc """
  Full validation of pipeline output: JSON Schema conformance (draft 2020-12)
  and round-trip comparison against source discovery data.

      mix ccxt_extract.validate
      mix ccxt_extract.validate --strict
      mix ccxt_extract.validate --schema-only

  ## Options

    * `--strict` — fail with non-zero exit if any errors found
    * `--schema-only` — skip round-trip comparison (faster)
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args, strict: [strict: :boolean, schema_only: :boolean])

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    Mix.shell().info("Validating pipeline output...")
    start = System.monotonic_time(:millisecond)

    validation_opts = [schema_only: opts[:schema_only] || false]

    {:ok, report} = CcxtExtract.Validation.validate_all(validation_opts)

    elapsed = System.monotonic_time(:millisecond) - start
    has_errors = report_results(report, elapsed)

    output_path = CcxtExtract.Paths.priv("output/_validation_report.json")
    CcxtExtract.Validation.write!(report, output_path)
    Mix.shell().info("Report: #{output_path}")

    if opts[:strict] && has_errors do
      Mix.raise("Validation found errors (strict mode). See report for details.")
    end
  end

  # Returns true if there are errors
  defp report_results(report, elapsed) do
    summary = report["summary"]
    ps = report["pipeline_stats"]

    Mix.shell().info("""
    Done in #{elapsed}ms. #{report["exchange_count"]} exchanges validated.
    Schema: #{summary["schema_pass"]} passed, #{summary["schema_fail"]} failed.
    Round-trip: #{summary["roundtrip_checked"]} checked, #{summary["roundtrip_clean"]} clean, #{summary["roundtrip_with_findings"]} with findings.
    Findings: #{summary["total_errors"]} errors, #{summary["total_warnings"]} warnings, #{summary["total_info"]} info.
    """)

    has_integrity_gaps =
      ps["missing_entries"] != [] || ps["corrupt_entries"] != [] || ps["orphan_entries"] != [] ||
        ps["id_mismatch_entries"] != []

    if has_integrity_gaps do
      Mix.shell().error("Pipeline data gaps:")

      for entry <- ps["missing_entries"],
          do: Mix.shell().error("  [missing] #{entry}")

      for entry <- ps["corrupt_entries"],
          do: Mix.shell().error("  [corrupt] #{entry}")

      for entry <- ps["orphan_entries"],
          do: Mix.shell().error("  [orphan] #{entry}")

      for entry <- ps["id_mismatch_entries"],
          do: Mix.shell().error("  [id_mismatch] #{entry}")
    end

    if summary["total_errors"] > 0 do
      Mix.shell().error("Errors:")

      report["findings_by_severity"]["error"]
      |> Enum.take(20)
      |> Enum.each(fn f ->
        Mix.shell().error("  [#{f["exchange_id"]}] #{f["path"]}: #{f["message"]}")
      end)
    end

    summary["total_errors"] > 0 || has_integrity_gaps
  end
end
