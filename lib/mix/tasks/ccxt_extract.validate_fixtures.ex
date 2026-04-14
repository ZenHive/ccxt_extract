defmodule Mix.Tasks.CcxtExtract.ValidateFixtures do
  @shortdoc "Check committed signing fixtures match fresh regeneration"

  @moduledoc """
  Regenerate signing fixtures in-memory via `CcxtExtract.SigningFixtures.extract/0`
  and diff against committed files in `priv/fixtures/signing/`. Volatile keys
  (`generated_at`) are stripped before diffing; everything else must match.

  Catches silent fixture drift: extractor changes or CCXT upgrades that alter
  output without anyone re-running `mix ccxt_extract.regenerate_fixtures`.

      mix ccxt_extract.validate_fixtures
      mix ccxt_extract.validate_fixtures --strict
      mix ccxt_extract.validate_fixtures --report /tmp/fixtures.json

  ## Options

    * `--fixtures DIR` — fixtures directory (default: `priv/fixtures/signing`).
    * `--report PATH` — report file location (default:
      `priv/discoveries/fixture_parity_report.json`). Kept outside the
      fixtures directory so it isn't picked up as a fixture on the next run.
    * `--strict` — exit non-zero if any drift (for CI).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [fixtures: :string, report: :string, strict: :boolean]
      )

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    fixtures_dir = opts[:fixtures] || CcxtExtract.Paths.priv("fixtures/signing")

    report_path =
      opts[:report] || CcxtExtract.Paths.priv("discoveries/fixture_parity_report.json")

    Mix.shell().info("Regenerating fixtures and diffing against #{fixtures_dir}...")
    start = System.monotonic_time(:millisecond)

    {:ok, report} = CcxtExtract.FixtureParity.check(fixtures_dir)

    elapsed = System.monotonic_time(:millisecond) - start
    report_results(report, elapsed)

    CcxtExtract.FixtureParity.write!(report, report_path)
    Mix.shell().info("Report: #{report_path}")

    if opts[:strict] && CcxtExtract.FixtureParity.has_drift?(report) do
      Mix.raise("Fixture parity check found drift (strict mode). See report for details.")
    end
  end

  defp report_results(report, elapsed) do
    s = report["summary"]

    Mix.shell().info("""
    Done in #{elapsed}ms. #{s["total"]} fixtures checked: \
    #{s["match"]} match, #{s["drift"]} drift, \
    #{s["missing_on_disk"]} missing, #{s["extra_on_disk"]} extra.
    """)

    report["exchanges"]
    |> Enum.reject(&(&1["status"] == "match"))
    |> Enum.take(20)
    |> Enum.each(fn e ->
      keys = e["diff_keys"] |> Enum.take(5) |> Enum.join(", ")
      Mix.shell().error("  [#{e["exchange"]}] #{e["status"]}: #{keys}")
    end)
  end
end
