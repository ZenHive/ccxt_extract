defmodule CcxtExtract.MarketValidationIntegrationTest do
  @moduledoc """
  Live spot-check tests for MarketValidation.
  Requires QuickBEAM + network — makes real API calls to exchanges.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.MarketValidation

  @moduletag :integration
  @moduletag :extraction
  # Network calls — generous timeout
  @moduletag timeout: 600_000

  # Small sample for spot-check — fast, reliable exchanges
  @spot_check_exchanges ~w(binance dydx)

  setup_all do
    # Load cached data for comparison
    load_markets_dir = CcxtExtract.Paths.priv("discoveries/load_markets")
    manifest = load_markets_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()

    cached_by_id =
      Map.new(manifest["succeeded"], fn id ->
        path = Path.join(load_markets_dir, "#{id}.json")
        data = path |> File.read!() |> Jason.decode!()
        {id, data}
      end)

    {:ok, spot_result} = MarketValidation.spot_check(cached_by_id, @spot_check_exchanges)

    %{spot_result: spot_result, cached_by_id: cached_by_id}
  end

  describe "spot_check/2" do
    test "returns comparison results", %{spot_result: result} do
      assert is_binary(result["checked_at"])
      assert result["exchanges_checked"] == @spot_check_exchanges
      assert is_list(result["results"])
      assert is_list(result["exchanges_failed"])
    end

    test "comparison results have expected structure", %{spot_result: result} do
      for comparison <- result["results"] do
        assert is_binary(comparison["id"])
        assert is_integer(comparison["market_count_fresh"])
        assert is_integer(comparison["symbols_added_count"])
        assert is_integer(comparison["symbols_removed_count"])
        assert is_binary(comparison["drift_summary"])
      end
    end

    test "binance has reasonable market count", %{spot_result: result} do
      binance = Enum.find(result["results"], &(&1["id"] == "binance"))

      if binance do
        # Binance typically has 2000+ markets — verify fresh count is reasonable
        assert binance["market_count_fresh"] >= 100,
               "binance should have at least 100 markets, got #{binance["market_count_fresh"]}"
      end
    end

    test "drift is not catastrophic", %{spot_result: result} do
      for comparison <- result["results"] do
        cached = comparison["market_count_cached"]
        fresh = comparison["market_count_fresh"]

        if cached && cached > 0 do
          # Market count should not change by more than 50% between runs
          ratio = fresh / cached

          assert ratio > 0.5 and ratio < 2.0,
                 "#{comparison["id"]}: suspicious drift — cached=#{cached}, fresh=#{fresh}"
        end
      end
    end
  end

  describe "validate/1 with spot_check" do
    @tag timeout: 600_000
    test "produces complete report with spot_check" do
      {:ok, report} =
        MarketValidation.validate(spot_check: true, scope: MapSet.new(@spot_check_exchanges))

      assert is_map(report["spot_check"])
      assert is_list(report["spot_check"]["results"])
      assert report["exchange_count"] >= 1
      assert report["summary"]["total_markets_checked"] > 0
    end
  end

  describe "mix task" do
    test "runs with --spot-check flag" do
      output =
        run_task_capturing_output(
          Mix.Tasks.CcxtExtract.ValidateMarkets,
          ["--spot-check" | Enum.flat_map(@spot_check_exchanges, &["--exchange", &1])]
        )

      assert output =~ "Validating"
      assert output =~ "Exchanges validated:"
      assert output =~ "Spot-check:"
    end
  end
end
