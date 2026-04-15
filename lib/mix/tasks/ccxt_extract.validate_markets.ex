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
      mix ccxt_extract.validate_markets --tier1
      mix ccxt_extract.validate_markets --spot-check --exchange binance --exchange bybit

  ## Options

    * `--spot-check` (or `-s`) — run Layer 2 spot-check after structural
      validation. Without scope, the spot-check sample defaults to the
      historical set (binance, bybit, okx). With scope, spot-check covers
      every in-scope exchange.
    * `--tier1 --tier2 --tier3 --dex` — restrict validation to the named
      priority tiers (combinable). Tier inheritance expands roots to their
      full family.
    * `--exchange ID` — restrict to explicit exchange IDs (repeatable or
      comma-separated). Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The legacy `--exchanges <csv>` flag has been replaced by canonical
  `--exchange ID` (repeatable). The active scope is stamped into the JSON
  envelope as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, opts} =
      TaskScope.parse_and_resolve!(args, [spot_check: :boolean], s: :spot_check)

    validate_opts = [scope: scope, spot_check: Keyword.get(opts, :spot_check, false)]

    Mix.shell().info("Validating loadMarkets() data...")

    start_time = System.monotonic_time(:millisecond)

    case CcxtExtract.MarketValidation.validate(validate_opts) do
      {:ok, report} ->
        elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000
        CcxtExtract.MarketValidation.write!(report, tier_scope: tier_scope)
        print_summary(report, elapsed_s)

      {:error, {:missing_input, path}} ->
        Mix.raise("""
        No loadMarkets() data found at: #{path}

        Run extraction first:
          mix ccxt_extract.load_markets
        """)
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
