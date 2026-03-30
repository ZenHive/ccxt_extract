defmodule Mix.Tasks.CcxtExtract.ValidateMarkets do
  @shortdoc "Validate extracted loadMarkets() data"

  @moduledoc """
  Validates cached loadMarkets() data for structural correctness and optionally
  spot-checks against live exchange API responses.

  Layer 1 (default): structural validation of cached JSON files — field presence,
  types, internal consistency, undefined density.

  Layer 2 (--spot-check): re-extracts a sample of exchanges via QuickBEAM and
  compares market counts and symbol sets against cached data.

      mix ccxt_extract.validate_markets
      mix ccxt_extract.validate_markets --spot-check
      mix ccxt_extract.validate_markets --spot-check --exchanges binance,bybit,okx
  """

  use Mix.Task

  @impl true
  def run(args) do
    opts = parse_args!(args)
    validate_opts = build_validate_opts(opts)

    Mix.shell().info("Validating loadMarkets() data...")

    start_time = System.monotonic_time(:millisecond)

    case CcxtExtract.MarketValidation.validate(validate_opts) do
      {:ok, report} ->
        elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000
        CcxtExtract.MarketValidation.write!(report)
        print_summary(report, elapsed_s)

      {:error, {:missing_input, path}} ->
        Mix.raise("""
        No loadMarkets() data found at: #{path}

        Run extraction first:
          mix ccxt_extract.load_markets
        """)
    end
  end

  defp parse_args!(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [spot_check: :boolean, exchanges: :string],
        aliases: [s: :spot_check, e: :exchanges]
      )

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}. Supported: --spot-check, --exchanges")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}. This task takes no positional arguments.")
    end

    if Keyword.has_key?(opts, :exchanges) and not Keyword.get(opts, :spot_check, false) do
      Mix.raise("--exchanges requires --spot-check (exchanges are only used for spot-checking)")
    end

    opts
  end

  defp build_validate_opts(opts) do
    validate_opts = []

    validate_opts =
      if Keyword.get(opts, :spot_check, false),
        do: Keyword.put(validate_opts, :spot_check, true),
        else: validate_opts

    case Keyword.get(opts, :exchanges) do
      nil -> validate_opts
      ids -> Keyword.put(validate_opts, :exchanges, String.split(ids, ","))
    end
  end

  defp print_summary(report, elapsed_s) do
    summary = report["summary"]

    Mix.shell().info("""
    Done in #{Float.round(elapsed_s, 1)}s.
      Exchanges validated: #{report["exchange_count"]}
      Markets checked: #{summary["total_markets_checked"]}
      Errors: #{summary["errors"]}
      Warnings: #{summary["warnings"]}
      Avg undefined density: #{summary["avg_undefined_density_pct"]}%
      Output: priv/discoveries/market_validation.json
    """)

    if report["spot_check"] do
      sc = report["spot_check"]
      Mix.shell().info("  Spot-check: #{length(sc["results"])} exchanges compared")

      for result <- sc["results"] do
        Mix.shell().info("    #{result["id"]}: #{result["drift_summary"]}")
      end

      if sc["exchanges_failed"] != [] do
        Mix.shell().info("    Failed: #{Enum.join(sc["exchanges_failed"], ", ")}")
      end
    end
  end
end
